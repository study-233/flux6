import Darwin
import Foundation

enum CapturedCommandError: Error { case invalidOutput, outputTooLarge, outputTimeout, readFailed }

struct CommandResult {
    let exit: ChildExit
    let output: Data
}

/// Bounded stdout for fixed system commands. Stderr stays on /dev/null; core
/// output is never captured by the service. Pipe consumption runs concurrently
/// with waitpid, so a full pipe cannot deadlock the child. The reader has its own
/// deadline even if a descendant unexpectedly inherits the writing endpoint.
enum CapturedCommand {
    static func run(executable: String, arguments: [String], directory: String = "/",
                    timeout: TimeInterval = 10, limit: Int = 1_048_576,
                    group: OwnedChildProcess.Group = .isolated) throws -> CommandResult {
        guard timeout.isFinite, timeout > 0, timeout <= 120, limit > 0, limit <= 2_097_152 else {
            throw ChildProcessError.invalidRequest
        }
        let pipe = Pipe()
        let collector = OutputCollector(input: pipe.fileHandleForReading, limit: limit, timeout: timeout + 6)
        collector.start()
        let result: Result<ChildExit, Error>
        do {
            let child = try OwnedChildProcess(executable: executable, arguments: arguments, directory: directory,
                group: group, standardOutput: pipe.fileHandleForWriting)
            try pipe.fileHandleForWriting.close()
            result = Result { try child.runToExit(timeout: timeout, gracePeriod: 1) }
        } catch {
            try? pipe.fileHandleForWriting.close()
            result = .failure(error)
        }
        let output = try collector.finish()
        return try CommandResult(exit: result.get(), output: output)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let input: FileHandle
    private let limit: Int
    private let deadline: UInt64
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    init(input: FileHandle, limit: Int, timeout: TimeInterval) {
        self.input = input; self.limit = limit
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    }

    func start() {
        DispatchQueue(label: "dev.freev6.command-output", qos: .utility).async {
            let value = Result { try self.read() }
            try? self.input.close()
            self.lock.lock(); self.result = value; self.lock.unlock()
            self.completion.signal()
        }
    }

    func finish() throws -> Data {
        guard completion.wait(timeout: DispatchTime(uptimeNanoseconds: deadline) + 1) == .success else {
            throw CapturedCommandError.outputTimeout
        }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }

    private func read() throws -> Data {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        let fd = input.fileDescriptor
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw CapturedCommandError.readFailed
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 { throw CapturedCommandError.readFailed }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CapturedCommandError.readFailed
            }
            if count == 0 { return data }
            guard count <= limit - data.count else { throw CapturedCommandError.outputTooLarge }
            data.append(contentsOf: bytes.prefix(count))
        }
        throw CapturedCommandError.outputTimeout
    }
}
