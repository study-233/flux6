#if !FREEV6_RELEASE_HOST
import Darwin
import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System

/// Only the separately identified acceptance build uses this backend. Every
/// mode/selection and speed read crosses a real child-process pipe. System
/// proxy, tunnel, DNS and privileged service installation are never invoked.
actor IsolatedHostSession: HostSession {
    static let nodes = ["东区", "西区", "北区"]
    let executable: URL
    private var child: FixtureChild?
    private var sessionID: UUID?
    private var settingsRevision: UInt64 = 0
    private var idle = UUID(), token = UUID()
    private var available: [SessionNodeGroup: [String]] = [:]
    private var installed = true
    private var fault: NetworkSessionPhase?
    private var rejectWrite = false
    init(executable: URL) { self.executable = executable }
    func health() -> DesktopServiceState { installed ? .ready : .missing }

    func status(_ id: UUID?) throws -> NetworkSessionReply {
        guard installed else { throw ServiceClientError.unavailable }
        if let child, !child.running { self.child = nil; sessionID = nil; idle = UUID() }
        return try statusReply()
    }

    private func statusReply() throws -> NetworkSessionReply {
        let id = UUID()
        let phase = fault ?? (child == nil ? .stopped : .running)
        var fields: [String: Any] = ["protocolVersion": ServiceProtocolVersion.current, "requestID": id.uuidString, "phase": phase.rawValue]
        if phase == .stopped { fields["idleToken"] = idle.uuidString }
        if (phase == .running || phase == .recoveryRequired), let sessionID {
            fields.merge(["sessionID": sessionID.uuidString, "revision": 1, "settingsRevision": settingsRevision,
                          "credentialRevision": sessionID.uuidString]) { _, new in new }
        }
        return try NetworkSessionReply.decode(JSONSerialization.data(withJSONObject: fields), id: id)
    }

    private func configuration(_ settings: SettingsSnapshot, worker: WorkerClient) async throws -> [SessionNodeGroup: [String]] {
        let saved = try await worker.settings()
        guard saved.revision == settings.revision else { throw WorkerClientError.staleConfiguration }
        var groups: [SessionNodeGroup: [String]] = [.access: saved.cloud?.enabled == true ? saved.cloud!.names : Self.nodes]
        if let chain = saved.chain, chain.enabled { groups[.chain] = chain.names }
        guard groups.values.allSatisfy({ !$0.isEmpty && $0.count <= 200 && Set($0).count == $0.count }),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HostFailure("prepare", "隔离节点列表或验收组件不可用。")
        }
        return groups
    }

    func check(_ settings: SettingsSnapshot, worker: WorkerClient, withService: Bool) async throws -> String {
        guard child == nil, fault == nil else { throw HostFailure("busy", "请先确认隔离会话已停止。") }
        let groups = try await configuration(settings, worker: worker)
        return "隔离配置检查通过 · 本地 worker 修订 \(settings.revision)，\(groups.values.reduce(0) { $0 + $1.count }) 个节点；未启动会话或检查系统核心。"
    }

    func start(_ idleToken: UUID, settings: SettingsSnapshot, worker: WorkerClient, interactive: Bool,
               authorize: @escaping @Sendable () async throws -> Void) async throws -> NetworkSessionReply {
        guard installed, fault == nil, child == nil, idleToken == idle else { throw ServiceClientError.unavailable }
        let groups = try await configuration(settings, worker: worker)
        try await authorize()
        let launched = try FixtureChild(executable: executable)
        _ = try launched.exchange("MODE " + settings.settings.mode.rawValue)
        available = groups
        child = launched; sessionID = UUID(); settingsRevision = settings.revision; token = UUID()
        return try statusReply()
    }

    func stop(_ id: UUID, revision: UInt64) throws -> NetworkSessionReply {
        guard let child, id == sessionID, revision == 1, fault != .occupied else { throw ServiceClientError.invalidReply }
        try child.stop()
        self.child = nil; sessionID = nil; fault = nil; idle = UUID()
        return try statusReply()
    }

    func scenario(_ name: String) throws {
        switch name {
        case "normal":
            fault = nil; rejectWrite = false; installed = true
            if let child { _ = try child.exchange("ZERO 0") }
        case "occupied": guard child == nil else { throw HostFailure("busy", "请先断开连接。") }; fault = .occupied
        case "recovering": guard child != nil else { throw HostFailure("idle", "请先连接再演示恢复。") }; fault = .recoveryRequired
        case "rejectNextWrite": rejectWrite = true
        case "zeroRate":
            guard let child else { throw HostFailure("idle", "请先连接再切换零速率。") }
            _ = try child.exchange("ZERO 1")
        default: throw HostFailure("invalid", "未知的验收场景。")
        }
    }

    func prepare(_ action: ServiceInstallationAction) throws {
        guard child == nil else { throw HostFailure("busy", "请先断开连接。") }
        installed = action != .uninstall; fault = nil; idle = UUID()
    }

    func control(_ query: SessionControlRequest) throws -> SessionControlReply {
        guard let child, child.running, fault == nil, query.target.sessionID == sessionID, query.target.revision == 1 else {
            throw HostFailure("staleSession", "这次网络会话已变化。")
        }
        let target = ["sessionID": query.target.sessionID.uuidString, "revision": 1] as [String: Any]
        var reply: [String: Any] = ["protocolVersion": ServiceProtocolVersion.current, "requestID": query.requestID.uuidString,
                                   "target": target, "action": query.action.rawValue]
        let memberIndex = query.group.flatMap { available[$0] }.flatMap { members in query.member.flatMap(members.firstIndex(of:)) }
        if [.select, .setMode, .unpin].contains(query.action) {
            guard query.token == token else { throw HostFailure("staleSession", "节点列表已更新，请重试。") }
            if rejectWrite {
                rejectWrite = false
                throw HostFailure("rejected", "验收进程未确认这次更改，请重试。")
            }
        }
        switch query.action {
        case .download:
            guard memberIndex != nil else { throw ServiceClientError.invalidReply }
            reply["download"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CoreDownloadResult(bytes: 8_000_000, seconds: 2)))
        case .cancelDownload: reply["cancelled"] = true
        case .traffic:
            let words = try child.exchange("TRAFFIC")
            guard words.count == 5, words[0] == "TRAFFIC" else { throw ServiceClientError.invalidReply }
            let values = words.dropFirst().compactMap(UInt64.init)
            guard values.count == 4 else { throw ServiceClientError.invalidReply }
            reply["traffic"] = Dictionary(uniqueKeysWithValues: zip(["up", "down", "upTotal", "downTotal"], values))
        case .delay:
            guard let memberIndex else { throw ServiceClientError.invalidReply }
            let words = try child.exchange("DELAY " + String(memberIndex))
            guard words.count == 2, words[0] == "DELAY", let ms = Int(words[1]) else { throw ServiceClientError.invalidReply }
            reply["delay"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CoreDelay.measured(milliseconds: ms)))
        default:
            switch query.action {
            case .select:
                guard let memberIndex else { throw ServiceClientError.invalidReply }
                _ = try child.exchange((query.group == .chain ? "CHAIN " : "NODE ") + String(memberIndex)); token = UUID()
            case .setMode:
                guard let mode = query.mode else { throw ServiceClientError.invalidReply }
                _ = try child.exchange("MODE " + mode.rawValue); token = UUID()
            case .unpin: _ = try child.exchange("NODE -1"); token = UUID()
            default: break
            }
            // Read independently after writing; the service reply validator also
            // checks that the selection/mode actually matches this request.
            let words = try child.exchange("STATE")
            guard words.count == 4, words[0] == "STATE", let index = Int(words[2]), let chain = Int(words[3]) else {
                throw ServiceClientError.invalidReply
            }
            let groups = try SessionNodeGroup.allCases.compactMap { group -> [String: Any]? in
                guard let names = available[group] else { return nil }
                let position = group == .access ? max(0, index) : chain
                guard names.indices.contains(position) else { throw ServiceClientError.invalidReply }
                var fields: [String: Any] = ["group": group.rawValue, "members": names, "selected": names[position], "automatic": group == .access]
                if group == .access && index >= 0 { fields["preferred"] = names[index] }
                return fields
            }
            reply["state"] = ["token": token.uuidString, "mode": String(words[1]), "groups": groups] as [String: Any]
        }
        return try SessionControlReply.decode(JSONSerialization.data(withJSONObject: reply), for: query)
    }
}

private final class FixtureChild {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    var running: Bool { process.isRunning }

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = ["session-fixture"]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
    }

    func exchange(_ request: String) throws -> [String] {
        guard process.isRunning else { throw HostFailure("childExited", "隔离会话进程已退出。") }
        try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        var ready = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var bytes = [UInt8](repeating: 0, count: 256)
        let readCount = poll(&ready, 1, 2000) == 1 ? bytes.withUnsafeMutableBytes {
            Darwin.read(ready.fd, $0.baseAddress, $0.count)
        } : -1
        // read(upToCount:) may wait for a full buffer on Darwin. Each child
        // reply is a single, bounded pipe write; read the available bytes once.
        guard readCount > 0, let line = String(bytes: bytes.prefix(readCount), encoding: .utf8), line.hasSuffix("\n") else {
            throw HostFailure("childTimeout", "隔离会话进程未响应。")
        }
        return line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func stop() throws {
        guard try exchange("STOP") == ["STOPPED"] else { throw ServiceClientError.invalidReply }
        process.waitUntilExit()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
#endif
