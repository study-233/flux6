import CryptoKit
import Darwin
import Foundation

enum SessionStoreError: Error, LocalizedError {
    case occupied, recoveryRequired, wrongOwner, invalidRecord, invalidTransition, integrity
    var errorDescription: String? {
        switch self {
        case .occupied: return "已有会话占用网络服务，请先完成停止或恢复"
        case .recoveryRequired: return "会话记录需要恢复，已保留原始资料"
        case .wrongOwner: return "当前用户不能操作其他用户的会话"
        case .invalidRecord: return "会话恢复记录无效，不能覆盖或清理"
        case .invalidTransition: return "会话状态不允许此操作"
        case .integrity: return "会话配置或资源校验失败"
        }
    }
}

/// v1 prepares files only. v2 permits a managed -t job, never TUN or DNS.
struct PreparedSessionRecord: Codable, Equatable {
    enum Phase: String, Codable { case preparing, prepared, checking }
    var schema: Int
    let sessionID: UUID
    let clientUID: uid_t
    let runtimeID: String
    let geodataID: String
    let settingsRevision: UInt64
    let credentialRevision: UUID
    let policyVersion: Int
    var phase: Phase
    var configurationSHA256: String?
    var check: CoreCheckRecord?

    init(request: ConfigurationCheckRequest, clientUID: uid_t) {
        schema = 1; sessionID = UUID(); self.clientUID = clientUID
        runtimeID = request.runtimeID; geodataID = request.geodataID
        settingsRevision = request.settingsRevision; credentialRevision = request.credentialRevision
        policyVersion = ServiceConfigurationAssembler.policyVersion; phase = .preparing
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw SessionStoreError.invalidRecord }
        do {
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SessionStoreError.invalidRecord }
            let required: Set<String> = ["schema", "sessionID", "clientUID", "runtimeID", "geodataID", "settingsRevision", "credentialRevision", "policyVersion", "phase"]
            guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["configurationSHA256", "check"])) else {
                throw SessionStoreError.invalidRecord
            }
            let record = try JSONDecoder().decode(Self.self, from: data)
            guard [1, 2].contains(record.schema), record.clientUID != 0, record.policyVersion > 0,
                  !record.runtimeID.isEmpty, record.runtimeID.utf8.count <= 128,
                  !record.geodataID.isEmpty, record.geodataID.utf8.count <= 128 else { throw SessionStoreError.invalidRecord }
            if record.schema == 1 {
                guard record.phase != .checking, record.check == nil, fields["check"] == nil else { throw SessionStoreError.invalidRecord }
            } else {
                guard record.phase == .checking, let check = record.check,
                      let object = fields["check"] as? [String: Any] else { throw SessionStoreError.invalidRecord }
                try check.validate(object)
            }
            if record.phase == .preparing {
                guard record.configurationSHA256 == nil else { throw SessionStoreError.invalidRecord }
            } else {
                guard let hash = record.configurationSHA256, hash.count == 64,
                      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SessionStoreError.invalidRecord }
            }
            return record
        } catch { throw SessionStoreError.invalidRecord }
    }
}

/// Owns the installation-shared network lock until released. A preparation
/// journal is written BEFORE creating the UUID directory or any secret file.
/// No deinit cleanup: a crash must leave durable evidence, not guess safety.
final class PreparedSessionStore {
    static let journalName = "network-session.json"
    static let filenames: Set<String> = ["mihomo", "GeoSite.dat", "geoip.dat", "country.mmdb", "config.json"]
    private let data: SecureDirectory
    private let sessions: SecureDirectory
    private let lease: FileHandle
    private let lock = NSLock()
    #if DEBUG
    var checkCheckpoint: ((String) -> Void)?
    #endif

    init(path: String = InstallationLayout.system.data, owner: uid_t = 0) throws {
        data = try SecureDirectory(path: path, owner: owner)
        // Registration is intentionally world-readable (0755 parent), whereas
        // this journal is 0600. Prevent inherited ACLs exposing new records.
        try data.requireNoAllowACL()
        lease = try data.acquireLock("network.lock")
        guard let directory = try data.privateChild("sessions", create: true) else { throw ResourceStoreError.io }
        sessions = directory
    }

    func current() throws -> PreparedSessionRecord? {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        return try load()
    }

    func prepare(_ request: ConfigurationCheckRequest, clientUID: uid_t,
                 populate: (SecureDirectory) throws -> Void) throws -> PreparedSessionRecord {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard clientUID != 0 else { throw SessionStoreError.wrongOwner }
        try ApprovedResourceCatalog.requirePair(runtimeID: request.runtimeID, geodataID: request.geodataID)
        guard try load() == nil else { throw SessionStoreError.occupied }
        guard try sessions.entries().isEmpty else { throw SessionStoreError.recoveryRequired }
        var record = PreparedSessionRecord(request: request, clientUID: clientUID)
        // Validate path length and assemble before making durable changes.
        let configuration = try ServiceConfigurationAssembler.assemble(request.configuration,
            sessionID: record.sessionID, sessionsDirectory: sessions.path)
        try persist(record)
        // Any following failure deliberately retains the journal. The caller
        // can explicitly recover preparation; no untracked credential files.
        guard let directory = try sessions.privateChild(record.sessionID.uuidString, create: true, exclusive: true) else {
            throw ResourceStoreError.io
        }
        try populate(directory)
        guard Set(try directory.entries()) == Self.filenames.subtracting(["config.json"]) else { throw SessionStoreError.integrity }
        try directory.write("config.json", data: configuration.data, mode: 0o600)
        try directory.requirePrivateFile("config.json")
        record.configurationSHA256 = Self.digest(configuration.data)
        record.phase = .prepared
        try persist(record)
        return record
    }

    /// Used by the forthcoming launch coordinator, before it records launch
    /// intent. Immutable copies remain valid if the download cache is replaced.
    func withVerifiedWorkspace<T>(sessionID: UUID, clientUID: uid_t, _ body: (SecureDirectory) throws -> T) throws -> T {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        let record = try requireRecord(sessionID: sessionID, clientUID: clientUID)
        return try body(verifiedWorkspace(record))
    }

    private func verifiedWorkspace(_ record: PreparedSessionRecord) throws -> SecureDirectory {
        guard record.phase == .prepared else { throw SessionStoreError.invalidTransition }
        guard let directory = try sessions.privateChild(record.sessionID.uuidString),
              Set(try directory.entries()) == Self.filenames else { throw SessionStoreError.integrity }
        try directory.requirePrivateFile("config.json")
        guard let config = try directory.read("config.json", limit: ServiceMessages.maximumConfigurationBytes),
              Self.digest(config) == record.configurationSHA256 else { throw SessionStoreError.integrity }
        let deadline = ResourceIO.deadline()
        for asset in ApprovedResourceCatalog.native {
            guard try directory.withFile(Self.filename(asset), { file in
                var metadata = stat()
                guard fstat(file, &metadata) == 0, metadata.st_mode & 0o7777 == asset.mode else { throw SessionStoreError.integrity }
                try ResourceIO.scan(file, limit: asset.limit, expected: asset.sha256, size: asset.size, deadline: deadline)
                if let arch = asset.architecture { try ResourceIO.verifyMachO(file, architecture: arch) }
                return true
            }) == true else { throw SessionStoreError.integrity }
        }
        return directory
    }

    /// Every side effect follows its durable intent. Errors in launchctl leave
    /// the record for a new service instance, not an unsafe best-effort delete.
    func checkConfiguration(sessionID: UUID, clientUID: uid_t) throws {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        var record = try requireRecord(sessionID: sessionID, clientUID: clientUID)
        let origin = try ServiceProcessOrigin.current()
        guard origin.ownerUID == data.owner else { throw SessionStoreError.wrongOwner }
        let directory = try verifiedWorkspace(record)
        let job = try makeJob(sessionID)
        record.schema = 2; record.phase = .checking
        record.check = CoreCheckRecord(origin: origin,
            coreSHA256: try ApprovedResourceCatalog.asset(record.runtimeID).sha256)
        try persist(record)
        try job.register(directory: directory, checkOnly: true)
        checkpoint("job-registered") // Crash after launchd ack, before journal.
        record.check!.stage = .registered; try persist(record)
        record.check!.stage = .starting; try persist(record)
        let pid = try job.start()
        checkpoint("job-started") // No child PID has been persisted yet.
        record.check!.pid = pid; record.check!.stage = .started; try persist(record)
        let exit: Int32
        var timedOut = false
        do { exit = try job.waitForExit(timeout: 20) }
        catch CoreJobError.timedOut { timedOut = true; exit = try job.stop() }
        record.check!.exitCode = exit; record.check!.stage = .exited; try persist(record)
        try job.removeStoppedJob()
        checkpoint("job-removed")
        record.check!.stage = .removed; try persist(record)
        try clean(record)
        if timedOut { throw CoreJobError.timedOut }
        guard exit == 0 else { throw ConfigurationCheckError.coreRejected }
    }

    /// Internal restart recovery. No caller-supplied PID, domain or job label.
    /// A record from this live service is not recovery authority: a failed
    /// launchctl might still be in flight. Keep it until its old group is gone.
    func recoverConfigurationCheck() throws {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard var record = try load() else {
            guard try sessions.entries().isEmpty else { throw SessionStoreError.recoveryRequired }
            return
        }
        guard record.schema == 2 else { try clean(record); return }
        let check = record.check!
        guard check.origin.ownerUID == data.owner else { throw SessionStoreError.wrongOwner }
        guard try check.origin.groupHasExited() else { throw SessionStoreError.occupied }
        let job = try makeJob(record.sessionID)
        let state = try job.status()
        if try check.origin.bootID != ServiceProcessOrigin.bootIdentity() {
            // Jobs live outside LaunchDaemons/LaunchAgents and do not reload
            // after a reboot. A same-label job in the new boot is unexpected.
            guard state == nil else { throw SessionStoreError.recoveryRequired }
        } else {
            switch check.stage {
            case .registering, .registered:
                if let state {
                    guard state.pid == nil else { throw SessionStoreError.recoveryRequired }
                    record.check!.exitCode = state.lastExit; record.check!.stage = .exited; try persist(record)
                    try job.removeStoppedJob()
                }
            case .starting, .started:
                guard state != nil else { throw SessionStoreError.recoveryRequired }
                record.check!.exitCode = try job.stop()
                record.check!.stage = .exited; try persist(record)
                try job.removeStoppedJob()
            case .exited:
                if let state {
                    guard state.pid == nil else { throw SessionStoreError.recoveryRequired }
                    try job.removeStoppedJob()
                }
            case .removed:
                guard state == nil else { throw SessionStoreError.recoveryRequired }
            }
        }
        record.check!.stage = .removed; try persist(record)
        try clean(record)
    }

    private func makeJob(_ sessionID: UUID) throws -> ManagedCoreJob {
        if data.owner == 0 { return ManagedCoreJob(sessionID: sessionID) }
        #if DEBUG
        guard data.owner == geteuid(), geteuid() != 0 else { throw SessionStoreError.wrongOwner }
        return try ManagedCoreJob(probeSessionID: sessionID, requireServiceOrigin: true)
        #else
        throw SessionStoreError.wrongOwner
        #endif
    }

    /// Safe only for this preparation-only schema, which cannot represent a
    /// launched core or DNS changes. No UID is supplied by a recovery caller;
    /// this is an internal service operation, never an arbitrary IPC delete.
    func recoverPreparation() throws {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard let record = try load() else {
            guard try sessions.entries().isEmpty else { throw SessionStoreError.recoveryRequired }
            return
        }
        guard record.schema == 1 else { throw SessionStoreError.invalidTransition }
        try clean(record)
    }

    func discard(sessionID: UUID, clientUID: uid_t) throws {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        let record = try requireRecord(sessionID: sessionID, clientUID: clientUID)
        guard record.schema == 1 else { throw SessionStoreError.invalidTransition }
        try clean(record)
    }

    private func clean(_ record: PreparedSessionRecord) throws {
        guard record.schema == 1 || (record.schema == 2 && record.check?.stage == .removed) else {
            throw SessionStoreError.invalidTransition
        }
        let allowed = record.schema == 2 ? Self.filenames.union([ManagedCoreJob.plistName, "cache.db"]) : Self.filenames
        let name = record.sessionID.uuidString
        guard Set(try sessions.entries()).isSubset(of: [name]) else { throw SessionStoreError.recoveryRequired }
        if let directory = try sessions.privateChild(name) {
            let entries = try directory.entries()
            // Check the entire set before deleting anything. Do not recurse,
            // follow links, or delete another session/unknown core output.
            for file in entries {
                let staging = file.hasPrefix(".staging-") && UUID(uuidString: String(file.dropFirst(9))) != nil
                guard allowed.contains(file) || staging else { throw SessionStoreError.recoveryRequired }
                _ = try directory.withFile(file) { _ in () }
            }
            for file in entries { try directory.removeRegularFile(file) }
            try sessions.removeEmptyChild(name, matching: directory)
        }
        try data.removeRegularFile(Self.journalName)
    }

    private func requireRecord(sessionID: UUID, clientUID: uid_t) throws -> PreparedSessionRecord {
        guard let record = try load(), record.sessionID == sessionID else { throw SessionStoreError.invalidTransition }
        guard record.clientUID == clientUID, clientUID != 0 else { throw SessionStoreError.wrongOwner }
        return record
    }

    private func load() throws -> PreparedSessionRecord? {
        try data.requirePrivateFile(Self.journalName)
        guard let bytes = try data.read(Self.journalName, limit: 4096) else { return nil }
        return try PreparedSessionRecord.decode(bytes)
    }

    private func persist(_ record: PreparedSessionRecord) throws {
        let encoded = try JSONEncoder().encode(record)
        _ = try PreparedSessionRecord.decode(encoded)
        try data.requirePrivateFile(Self.journalName)
        try data.write(Self.journalName, data: encoded, mode: 0o600)
        try data.requirePrivateFile(Self.journalName)
        if let check = record.check { checkpoint(check.stage.rawValue) }
    }

    private func checkpoint(_ name: String) {
        #if DEBUG
        checkCheckpoint?(name)
        #endif
    }

    static func filename(_ asset: ApprovedResource) -> String {
        asset.architecture == nil ? String(asset.id.split(separator: "/")[1]) : "mihomo"
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
