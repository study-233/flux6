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

/// v1 prepares files, v2 checks configuration, v3 owns a running network session.
struct PreparedSessionRecord: Codable, Equatable {
    enum Phase: String, Codable { case preparing, prepared, checking, network }
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
    var run: NetworkRunRecord?

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
            guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["configurationSHA256", "check", "run"])) else {
                throw SessionStoreError.invalidRecord
            }
            let record = try JSONDecoder().decode(Self.self, from: data)
            guard [1, 2, 3].contains(record.schema), record.clientUID != 0, record.policyVersion > 0,
                  !record.runtimeID.isEmpty, record.runtimeID.utf8.count <= 128,
                  !record.geodataID.isEmpty, record.geodataID.utf8.count <= 128 else { throw SessionStoreError.invalidRecord }
            switch record.schema {
            case 1:
                guard [.preparing, .prepared].contains(record.phase), fields["check"] == nil, fields["run"] == nil else {
                    throw SessionStoreError.invalidRecord
                }
            case 2:
                guard record.phase == .checking, fields["run"] == nil, let check = record.check,
                      let object = fields["check"] as? [String: Any] else { throw SessionStoreError.invalidRecord }
                try check.validate(object)
            case 3:
                guard record.phase == .network, fields["check"] == nil, let run = record.run,
                      let object = fields["run"] as? [String: Any] else { throw SessionStoreError.invalidRecord }
                try run.validate(object)
            default: throw SessionStoreError.invalidRecord
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
    var probeConfiguration: ((Data, UUID) throws -> Data)?
    var probeNetwork: ((SecureDirectory, ManagedCoreJob) throws -> any SessionRunNetwork)?

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
        var configData = configuration.data
        #if DEBUG
        if data.owner == geteuid(), data.owner != 0, let probeConfiguration {
            configData = try probeConfiguration(configData, record.sessionID)
        }
        #endif
        try persist(record)
        // Any following failure deliberately retains the journal. The caller
        // can explicitly recover preparation; no untracked credential files.
        guard let directory = try sessions.privateChild(record.sessionID.uuidString, create: true, exclusive: true) else {
            throw ResourceStoreError.io
        }
        try populate(directory)
        guard Set(try directory.entries()) == Self.filenames.subtracting(["config.json"]) else { throw SessionStoreError.integrity }
        try directory.write("config.json", data: configData, mode: 0o600)
        try directory.requirePrivateFile("config.json")
        record.configurationSHA256 = Self.digest(configData)
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
    func recoverInterruptedSession() throws {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard var record = try load() else {
            guard try sessions.entries().isEmpty else { throw SessionStoreError.recoveryRequired }
            return
        }
        if record.schema == 3 {
            guard let run = record.run, run.origin.ownerUID == data.owner,
                  try run.origin.groupHasExited() else { throw SessionStoreError.occupied }
            try finishRun(&record)
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

    /// Caller retains this store and its installation-wide lease from
    /// preparation until stop has restored DNS and removed the job and files.
    func startRunning(sessionID: UUID, clientUID: uid_t) throws -> PreparedSessionRecord {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        var record = try requireRecord(sessionID: sessionID, clientUID: clientUID)
        let origin = try ServiceProcessOrigin.current()
        guard origin.ownerUID == data.owner, record.policyVersion == ServiceConfigurationAssembler.policyVersion else {
            throw SessionStoreError.invalidTransition
        }
        let directory = try verifiedWorkspace(record)
        guard let config = try directory.read("config.json", limit: ServiceMessages.maximumConfigurationBytes),
              let object = try JSONSerialization.jsonObject(with: config) as? [String: Any],
              let providers = object["rule-providers"] as? [String: Any] else { throw SessionStoreError.integrity }
        let job = try makeJob(sessionID)
        let network = try networkEnvironment(directory, job: job)
        guard try job.status() == nil else { throw SessionStoreError.occupied }
        record.schema = 3
        record.phase = .network
        record.run = NetworkRunRecord(origin: origin, ruleFiles: providers.keys.map { $0 + ".list" }.sorted())
        try persist(record)

        // An unacknowledged launchctl mutation can still be in flight. In
        // that case the next daemon waits for the old command group to exit.
        var mutationInFlight = false
        do {
            try network.prepareDNS()
            try advance(&record, to: .registering)
            mutationInFlight = true
            try job.register(directory: directory, checkOnly: false)
            mutationInFlight = false
            checkpoint("run-job-registered")
            try advance(&record, to: .starting)
            mutationInFlight = true
            let pid = try job.start()
            mutationInFlight = false
            checkpoint("run-job-started")
            let tunnel = try network.checkReadiness(pid: pid)
            guard try job.status()?.pid == pid else { throw NetworkRunError.tunnelUnavailable }
            record.run!.tunnel = tunnel
            try advance(&record, to: .applyingDNS)
            try network.applyDNS()
            checkpoint("run-dns-applied")
            try network.verifyEgress(tunnel)
            guard try job.status()?.pid == pid, try network.ownedTunnel(pid: pid) == tunnel else {
                throw NetworkRunError.tunnelUnavailable
            }
            try advance(&record, to: .active)
            return record
        } catch {
            if mutationInFlight { throw NetworkRunError.recoveryRequired }
            // Reload durable intent. A failed journal fsync is ambiguous.
            guard var pending = try load(), pending.sessionID == sessionID else { throw NetworkRunError.recoveryRequired }
            try finishRun(&pending)
            throw error
        }
    }

    func stopRunning(sessionID: UUID, clientUID: uid_t, revision: UInt64) throws {
        guard lock.try() else { throw SessionStoreError.occupied }
        defer { lock.unlock() }
        guard var record = try load() else {
            guard try sessions.entries().isEmpty else { throw SessionStoreError.recoveryRequired }
            return
        }
        guard clientUID != 0, record.clientUID == clientUID else { throw SessionStoreError.wrongOwner }
        guard record.schema == 3, record.sessionID == sessionID, let run = record.run,
              run.revision == revision else { throw SessionStoreError.invalidTransition }
        let origin = try ServiceProcessOrigin.current()
        if origin != run.origin {
            guard try run.origin.groupHasExited() else { throw SessionStoreError.occupied }
        } else if [.registering, .starting].contains(run.stage) {
            // This instance may have lost its own bootstrap/kickstart reply.
            throw NetworkRunError.recoveryRequired
        }
        try finishRun(&record)
    }

    private func advance(_ record: inout PreparedSessionRecord, to stage: NetworkRunRecord.Stage) throws {
        guard var run = record.run, run.revision < UInt64.max - 1 else { throw SessionStoreError.invalidRecord }
        run.stage = stage
        run.revision += 1
        record.run = run
        try persist(record)
    }

    private func networkEnvironment(_ directory: SecureDirectory, job: ManagedCoreJob) throws -> any SessionRunNetwork {
        #if DEBUG
        if data.owner != 0, data.owner == geteuid(), let probeNetwork { return try probeNetwork(directory, job) }
        #endif
        return try SystemRunNetwork(directory: directory, job: job)
    }

    private func finishRun(_ record: inout PreparedSessionRecord) throws {
        guard let run = record.run, run.origin.ownerUID == data.owner else { throw SessionStoreError.wrongOwner }
        let job = try makeJob(record.sessionID)
        if run.stage == .removed {
            guard try job.status() == nil else { throw NetworkRunError.recoveryRequired }
            try clean(record)
            return
        }
        guard let directory = try sessions.privateChild(record.sessionID.uuidString) else { throw NetworkRunError.recoveryRequired }
        let network = try networkEnvironment(directory, job: job)
        if [.starting, .applyingDNS, .active].contains(run.stage) {
            // Publish stop intent before touching DNS. A failed rollback must
            // never leave a durable status claiming that this session is up.
            try advance(&record, to: .restoringDNS)
        }
        let hasJournal = try directory.entries().contains(SessionDNSTransaction.journalName)
        if hasJournal { try network.restoreDNS() }
        else if run.stage != .capturingDNS { throw NetworkRunError.recoveryRequired }
        checkpoint("run-dns-restored")
        // DNS rollback precedes job inspection, even if the job crashed or
        // disappeared. An unconfirmed job must not strand system DNS.
        let state = try job.status()
        let sameBoot = try ServiceProcessOrigin.bootIdentity() == run.origin.bootID
        if !sameBoot {
            guard state == nil else { throw NetworkRunError.recoveryRequired }
        } else {
            switch run.stage {
            case .capturingDNS:
                guard state == nil else { throw NetworkRunError.recoveryRequired }
            case .registering:
                guard state?.pid == nil else { throw NetworkRunError.recoveryRequired }
            case .starting, .applyingDNS, .active, .restoringDNS, .stopping:
                guard let state else { throw NetworkRunError.recoveryRequired }
                if record.run!.tunnel == nil, let pid = state.pid {
                    let candidate = try network.ownedTunnel(pid: pid)
                    guard try job.status()?.pid == pid else { throw NetworkRunError.recoveryRequired }
                    record.run!.tunnel = candidate
                }
                if run.stage != .stopping { try advance(&record, to: .stopping) }
                _ = try job.stop()
                checkpoint("run-job-stopped")
            case .exited:
                guard state?.pid == nil else { throw NetworkRunError.recoveryRequired }
            case .removed: throw SessionStoreError.invalidTransition
            }
            if let tunnel = record.run!.tunnel { try network.verifyRelease(tunnel) }
        }
        if record.run!.stage != .exited {
            // A pre-capture failure with no DNS journal must survive partial
            // cleanup without acquiring an artificial DNS obligation.
            if !hasJournal { try advance(&record, to: .removed); try clean(record); return }
            try advance(&record, to: .exited)
        }
        if state != nil { try job.removeStoppedJob() }
        checkpoint("run-job-removed")
        try advance(&record, to: .removed)
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
        guard record.schema == 1 || (record.schema == 2 && record.check?.stage == .removed) || (record.schema == 3 && record.run?.stage == .removed) else {
            throw SessionStoreError.invalidTransition
        }
        var allowed = Self.filenames
        if record.schema >= 2 { allowed.formUnion([ManagedCoreJob.plistName, "cache.db"]) }
        if record.schema == 3 { allowed.insert(SessionDNSTransaction.journalName) }
        let name = record.sessionID.uuidString
        guard Set(try sessions.entries()).isSubset(of: [name]) else { throw SessionStoreError.recoveryRequired }
        if let directory = try sessions.privateChild(name) {
            let entries = try directory.entries()
            // Check the entire set before deleting anything. Do not recurse,
            // follow links, or delete another session/unknown core output.
            var rules: SecureDirectory?
            var ruleFiles: [String] = []
            for file in entries {
                if record.schema == 3, file == "c.sock" {
                    try directory.requireOwnedSocket(file)
                    continue
                }
                if let run = record.run, file == "ruleset" {
                    guard let child = try directory.privateChild(file) else { throw SessionStoreError.integrity }
                    ruleFiles = try child.entries()
                    guard Set(ruleFiles).isSubset(of: Set(run.ruleFiles)) else { throw SessionStoreError.recoveryRequired }
                    for name in ruleFiles { _ = try child.withFile(name) { _ in () } }
                    rules = child
                    continue
                }
                let staging = file.hasPrefix(".staging-") && UUID(uuidString: String(file.dropFirst(9))) != nil
                guard allowed.contains(file) || staging else { throw SessionStoreError.recoveryRequired }
                _ = try directory.withFile(file) { _ in () }
            }
            if let rules {
                for name in ruleFiles { try rules.removeRegularFile(name) }
                try directory.removeEmptyChild("ruleset", matching: rules)
            }
            if record.schema == 3, entries.contains("c.sock") { try directory.removeOwnedSocket("c.sock") }
            for file in entries where file != "ruleset" && file != "c.sock" { try directory.removeRegularFile(file) }
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
        if let run = record.run { checkpoint("run-" + run.stage.rawValue) }
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
