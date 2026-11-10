import Darwin
import Foundation

enum ChildProcessError: Error, LocalizedError, Equatable {
    case invalidRequest, spawnFailed(Int32), ownershipLost, signalFailed(Int32), timedOut, notReaped
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "子进程启动参数不符合要求"
        case .spawnFailed(let code): return "无法启动受控子进程（\(code)）"
        case .ownershipLost: return "无法确认子进程归属，已停止发送信号"
        case .signalFailed(let code): return "无法终止子进程（\(code)）"
        case .timedOut: return "子进程操作超时，已终止并回收"
        case .notReaped: return "子进程尚未完成回收"
        }
    }
}

enum ChildExit: Equatable {
    case exited(Int32), signaled(Int32)
}

struct ChildStop: Equatable {
    let exit: ChildExit
    let forced: Bool
}

/// Owns one child from posix_spawn through waitpid. No caller-supplied PID,
/// shell, inherited environment, or inherited file descriptors. The caller
/// must validate the executable/configuration and retain this object until
/// its network cleanup and explicit stop have completed.
final class OwnedChildProcess {
    enum Group { case isolated, inheritService }
    private let state: ChildState
    var pid: pid_t { state.pid }

    init(executable: String, arguments: [String], directory: String, group: Group = .isolated,
         standardOutput: FileHandle? = nil) throws {
        if group == .inheritService { _ = try ServiceProcessOrigin.current() }
        let strings = [executable, directory] + arguments
        guard executable.hasPrefix("/"), directory.hasPrefix("/"), arguments.count <= 32,
              strings.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 8192 }),
              strings.reduce(0, { $0 + $1.utf8.count }) <= 32768 else { throw ChildProcessError.invalidRequest }
        var actions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Open standard descriptors explicitly. Dropping output prevents a
        // configuration parser from leaking credentials into daemon logs.
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            if fd == STDOUT_FILENO, let output = standardOutput {
                guard output.fileDescriptor > STDERR_FILENO else { throw ChildProcessError.invalidRequest }
                try Self.check(posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, fd))
                continue
            }
            try Self.check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
        }
        if #available(macOS 26, *) {
            try Self.check(posix_spawn_file_actions_addchdir(&actions, directory))
        } else {
            try Self.check(posix_spawn_file_actions_addchdir_np(&actions, directory))
        }
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        if group == .isolated {
            try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
            flags |= POSIX_SPAWN_SETPGROUP
        }
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        var child: pid_t = 0
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C"]
        try Self.withCStringArray([executable] + arguments) { argv in
            try Self.withCStringArray(environment) { envp in
                try Self.check(posix_spawn(&child, executable, &actions, &attributes, argv, envp))
            }
        }
        let owned = ChildState(pid: child)
        state = owned
        // waitid(WNOWAIT) waits without freeing the PID. All reaping and signal
        // delivery happens under the same lock, preventing a kill-after-reap
        // race against PID reuse. The observer owns state, not this wrapper.
        DispatchQueue(label: "dev.freev6.child.\(child)", qos: .utility).async { owned.observeExit() }
    }

    deinit { _ = try? stop(gracePeriod: 0.25, killWait: 2) }

    func wait(timeout: TimeInterval) throws -> ChildExit? { try state.wait(timeout: timeout) }

    @discardableResult
    func stop(gracePeriod: TimeInterval = 3, killWait: TimeInterval = 3) throws -> ChildStop {
        try ChildState.validateTimeout(gracePeriod); try ChildState.validateTimeout(killWait)
        if let exit = try wait(timeout: 0) { return ChildStop(exit: exit, forced: false) }
        _ = try state.signal(SIGTERM)
        if let exit = try wait(timeout: gracePeriod) { return ChildStop(exit: exit, forced: false) }
        let forced = try state.signal(SIGKILL)
        guard let exit = try wait(timeout: killWait) else { throw ChildProcessError.notReaped }
        return ChildStop(exit: exit, forced: forced)
    }

    func runToExit(timeout: TimeInterval, gracePeriod: TimeInterval = 3) throws -> ChildExit {
        try ChildState.validateTimeout(timeout); try ChildState.validateTimeout(gracePeriod)
        if let exit = try wait(timeout: timeout) { return exit }
        _ = try stop(gracePeriod: gracePeriod)
        throw ChildProcessError.timedOut
    }

    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw ChildProcessError.spawnFailed(code) }
    }

    private static func withCStringArray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers = [UnsafeMutablePointer<CChar>?]()
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let copy = strdup(string) else { throw ChildProcessError.spawnFailed(ENOMEM) }
            pointers.append(copy)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}

private final class ChildState: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var result: Result<ChildExit, ChildProcessError>?

    init(pid: pid_t) { self.pid = pid; completion.enter() }

    static func validateTimeout(_ value: TimeInterval) throws {
        guard value.isFinite, value >= 0, value <= 3600 else { throw ChildProcessError.invalidRequest }
    }

    func wait(timeout: TimeInterval) throws -> ChildExit? {
        try Self.validateTimeout(timeout)
        lock.lock()
        let immediate = result
        lock.unlock()
        if let immediate { return try immediate.get() }
        if completion.wait(timeout: .now() + timeout) != .success { return nil }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }

    func signal(_ signal: Int32) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let result { _ = try result.get(); return false }
        if kill(pid, signal) == 0 { return true }
        let code = errno
        if code == ESRCH { return false }
        throw ChildProcessError.signalFailed(code)
    }

    func observeExit() {
        var info = siginfo_t()
        var status: Int32
        repeat { status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while status < 0 && errno == EINTR
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        guard status == 0 else { finishLocked(.failure(.ownershipLost)); return }
        reapLocked()
        if result == nil { finishLocked(.failure(.ownershipLost)) }
    }

    private func reapLocked() {
        // Only the observer may reap. Otherwise it could begin waitid after
        // another thread freed the PID, then accidentally wait on a new child
        // with the same PID. Signal delivery also uses this lock.
        guard result == nil else { return }
        var status: Int32 = 0
        var child: pid_t
        repeat { child = waitpid(pid, &status, WNOHANG) } while child < 0 && errno == EINTR
        if child == 0 { return }
        guard child == pid else { finishLocked(.failure(.ownershipLost)); return }
        // sys/wait.h: low seven bits are the terminating signal (zero for a
        // normal exit), high byte is the exit code. No stopped states requested.
        let signal = status & 0x7f
        if signal == 0 { finishLocked(.success(.exited((status >> 8) & 0xff))) }
        else if signal != 0x7f { finishLocked(.success(.signaled(signal))) }
        else { finishLocked(.failure(.ownershipLost)) }
    }

    private func finishLocked(_ value: Result<ChildExit, ChildProcessError>) {
        guard result == nil else { return }
        result = value
        completion.leave()
    }
}
