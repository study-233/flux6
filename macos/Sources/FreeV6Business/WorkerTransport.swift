import Foundation
import Darwin

// All blocking pipe IO runs outside Swift's cooperative executor and main
// thread. The stream and write queue are bounded, including during shutdown.
final class WorkerTransport: @unchecked Sendable {
    let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let writer = DispatchQueue(label: "dev.freev6.worker.write")
    private let lock = NSLock()
    private var closed = false
    private var queuedWrites = 0
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(location: WorkerLocation) throws {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        messages = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { continuation = $0 }
        self.continuation = continuation
        guard FileManager.default.isExecutableFile(atPath: location.executable.path) else {
            throw WorkerClientError.notAvailable
        }
        process.executableURL = location.executable
        process.arguments = ["--data-dir", location.data.path, "--resource-dir", location.resources.path,
                             "--cache-dir", location.cache.path, "--log-dir", location.logs.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw WorkerClientError.notAvailable
        }
        process.terminationHandler = { [weak self] _ in self?.didExit() }
        try process.run()
        // Only the child owns these ends. Closing the parent's copies makes
        // EOF deterministic when the worker dies or this client shuts down.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        DispatchQueue(label: "dev.freev6.worker.read").async { self.readMessages() }
        DispatchQueue(label: "dev.freev6.worker.stderr").async {
            // Drain without retaining credential-bearing diagnostics. The UI
            // reports structured protocol errors; diagnostic export is separate.
            while let data = try? Self.readChunk(self.diagnostics.fileHandleForReading, limit: 16_384), !data.isEmpty {}
            try? self.diagnostics.fileHandleForReading.close()
        }
    }

    private func readMessages() {
        defer { try? output.fileHandleForReading.close(); close() }
        var decoder = WorkerFrameDecoder()
        do {
            while true {
                let data = try Self.readChunk(output.fileHandleForReading, limit: 65_536)
                if data.isEmpty { break }
                for frame in try decoder.append(data) {
                    switch continuation.yield(frame) {
                    case .enqueued: break
                    case .dropped: throw WorkerClientError.busy
                    case .terminated: return
                    @unknown default: throw WorkerClientError.disconnected
                    }
                }
            }
            try decoder.finish()
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }

    private static func readChunk(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data(count: limit)
        while true {
            let count = data.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, limit) }
            if count >= 0 { return Data(data.prefix(count)) }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        guard !closed, queuedWrites < 16 else {
            lock.unlock(); completion(WorkerClientError.disconnected); return
        }
        queuedWrites += 1
        lock.unlock()
        writer.async {
            var failure: Error?
            do { try self.input.fileHandleForWriting.write(contentsOf: data) } catch { failure = error }
            self.lock.lock(); self.queuedWrites -= 1; self.lock.unlock()
            completion(failure)
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        continuation.finish()
        // Closing stdin requests normal worker shutdown. A wedged worker is
        // terminated after a bounded grace period and reaped off the UI thread.
        DispatchQueue.global(qos: .utility).async { try? self.input.fileHandleForWriting.close() }
        let child = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if child.isRunning { child.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited { lock.unlock(); continuation.resume() }
            else { exitWaiters.append(continuation); lock.unlock() }
        }
    }

    private func didExit() {
        lock.lock()
        exited = true
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}
