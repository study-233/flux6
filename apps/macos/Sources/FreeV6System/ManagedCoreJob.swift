import Darwin
import Foundation

enum CoreJobError: Error, LocalizedError {
    case invalidState, unavailable, timedOut, commandFailed, wrongContext
    var errorDescription: String? {
        switch self {
        case .invalidState: return "核心任务状态不符合预期，已保留恢复记录"
        case .unavailable: return "无法查询核心任务，请保留恢复记录"
        case .timedOut: return "核心任务未在规定时间内结束"
        case .commandFailed: return "无法完成核心任务管理操作"
        case .wrongContext: return "核心任务只能由网络服务管理"
        }
    }
}

struct CoreJobStatus: Equatable {
    let pid: pid_t?
    /// launchctl list documents a normal exit code or a negative signal.
    let lastExit: Int32
}

/// One UUID-named, explicitly started launchd job per session. launchd owns the
/// core itself, not just a parent whose orphaned children may ignore SIGTERM.
/// Caller MUST persist intent before register/start and persist the confirmed
/// exit before remove. This layer never deletes private configuration files.
final class ManagedCoreJob {
    static let plistName = "core-job.plist"
    let sessionID: UUID
    var label: String { "dev.freev6.core." + sessionID.uuidString.lowercased() }
    private let domain: String
    private let ordinaryUserProbe: Bool
    private let requiresServiceOrigin: Bool
    private var target: String { domain + "/" + label }

    init(sessionID: UUID) {
        self.sessionID = sessionID; domain = "system"; ordinaryUserProbe = false; requiresServiceOrigin = true
    }

    #if DEBUG
    init(probeSessionID: UUID, requireServiceOrigin: Bool = false) throws {
        guard geteuid() != 0 else { throw CoreJobError.wrongContext }
        sessionID = probeSessionID; domain = "gui/\(geteuid())"; ordinaryUserProbe = true
        requiresServiceOrigin = requireServiceOrigin
    }
    #endif

    func definition(directory: SecureDirectory, checkOnly: Bool) throws -> Data {
        try directory.requirePrivate()
        guard URL(fileURLWithPath: directory.path).lastPathComponent == sessionID.uuidString else {
            throw CoreJobError.invalidState
        }
        // env execs the fixed core in place, so launchd still owns its PID.
        // EnvironmentVariables alone would merge with launchd's environment.
        let arguments = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C",
                         directory.path + "/mihomo"] + (checkOnly ? ["-t"] : []) +
            ["-d", directory.path, "-f", directory.path + "/config.json"]
        let value: [String: Any] = [
            "Label": label, "ProgramArguments": arguments, "WorkingDirectory": directory.path,
            // Registering a job never starts a core. After registration is
            // acknowledged, the journal must record intent before kickstart.
            "RunAtLoad": false, "KeepAlive": false, "AbandonProcessGroup": false,
            "ExitTimeOut": 5, "ProcessType": "Standard", "Umask": 0o077,
            "StandardInPath": "/dev/null", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
            "SoftResourceLimits": ["Core": 0], "HardResourceLimits": ["Core": 0],
        ]
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    func register(directory: SecureDirectory, checkOnly: Bool) throws {
        guard try status() == nil else { throw CoreJobError.invalidState }
        try directory.write(Self.plistName, data: definition(directory: directory, checkOnly: checkOnly), mode: 0o600)
        try directory.requirePrivateFile(Self.plistName)
        _ = try command(["bootstrap", domain, directory.path + "/" + Self.plistName], mutation: true)
        guard let state = try status(), state.pid == nil else { throw CoreJobError.invalidState }
    }

    @discardableResult
    func start() throws -> pid_t {
        guard let state = try status(), state.pid == nil else { throw CoreJobError.invalidState }
        let bytes = try command(["kickstart", "-p", target], mutation: true)
        guard let text = String(data: bytes, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw CoreJobError.invalidState
        }
        return pid // diagnostic only; never used as a signal target
    }

    func status() throws -> CoreJobStatus? {
        // Unlike print's explicitly unstable diagnostic text, the launchctl
        // manual specifies the three list columns. Never parse `print` output
        // or use the deprecated, unstable SMJobCopyDictionary dictionary.
        try Self.parseList(command(["list"], mutation: false), label: label)
    }

    func waitForExit(timeout: TimeInterval) throws -> Int32 {
        guard timeout.isFinite, timeout >= 0, timeout <= 120 else { throw CoreJobError.invalidState }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            guard let state = try status() else { throw CoreJobError.invalidState }
            if state.pid == nil { return state.lastExit }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        throw CoreJobError.timedOut
    }

    /// Retains the stopped job so a crash before journaling the exit can be
    /// reconciled. Only launchd receives signals, addressed to our UUID label.
    @discardableResult
    func stop(gracePeriod: TimeInterval = 3) throws -> Int32 {
        guard gracePeriod.isFinite, gracePeriod >= 0, gracePeriod <= 10 else { throw CoreJobError.invalidState }
        guard let state = try status() else { throw CoreJobError.invalidState }
        if state.pid == nil { return state.lastExit }
        try signal("SIGTERM")
        do { return try waitForExit(timeout: gracePeriod) }
        catch CoreJobError.timedOut {
            try signal("SIGKILL")
            return try waitForExit(timeout: 5)
        }
    }

    func removeStoppedJob() throws {
        guard let state = try status(), state.pid == nil else { throw CoreJobError.invalidState }
        _ = try command(["bootout", target], mutation: true)
        guard try status() == nil else { throw CoreJobError.invalidState }
    }

    private func signal(_ name: String) throws {
        do { _ = try command(["kill", name, target], mutation: true) }
        catch {
            // A process can exit between the status query and launchctl kill.
            // Accept only an authoritative stopped job; absence is ambiguous.
            guard let state = try status(), state.pid == nil else { throw error }
        }
    }

    private func command(_ arguments: [String], mutation: Bool) throws -> Data {
        let group: OwnedChildProcess.Group
        if ordinaryUserProbe {
            guard geteuid() != 0 else { throw CoreJobError.wrongContext }
            if requiresServiceOrigin { _ = try ServiceProcessOrigin.current() }
            group = mutation && requiresServiceOrigin ? .inheritService : .isolated
        } else {
            guard geteuid() == 0 else { throw CoreJobError.wrongContext }
            _ = try ServiceProcessOrigin.current()
            group = mutation ? .inheritService : .isolated
        }
        let result = try CapturedCommand.run(executable: "/bin/launchctl", arguments: arguments, group: group)
        guard result.exit == .exited(0) else { throw CoreJobError.commandFailed }
        return result.output
    }

    static func parseList(_ bytes: Data, label: String) throws -> CoreJobStatus? {
        guard !bytes.isEmpty, bytes.count <= 1_048_576, let text = String(data: bytes, encoding: .utf8) else {
            throw CoreJobError.unavailable
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last?.isEmpty == true,
              lines[0].split(whereSeparator: \.isWhitespace).map(String.init) == ["PID", "Status", "Label"] else {
            throw CoreJobError.unavailable
        }
        var found: CoreJobStatus?
        for line in lines.dropFirst().dropLast() {
            let values = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard values.count == 3, let exit = Int32(values[1]), (-128...255).contains(exit) else {
                throw CoreJobError.unavailable
            }
            let pid: pid_t?
            if values[0] == "-" { pid = nil }
            else {
                guard let value = pid_t(values[0]), value > 1 else { throw CoreJobError.unavailable }
                pid = value
            }
            if values[2] == label {
                guard found == nil else { throw CoreJobError.unavailable }
                found = CoreJobStatus(pid: pid, lastExit: exit)
            }
        }
        return found
    }
}
