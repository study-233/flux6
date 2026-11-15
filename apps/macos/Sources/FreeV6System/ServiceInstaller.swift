import CryptoKit
import Darwin
import Foundation

public enum InstallationError: Error, LocalizedError {
    case busy, invalidPayload, inconsistentInstallation, recoveryRequired, networkRecoveryRequired
    case launchd(String)
    public var errorDescription: String? {
        switch self {
        case .busy: return "网络服务正在处理另一项操作，请稍后重试"
        case .invalidPayload: return "安装包的代码身份、架构或固定摘要不符合要求"
        case .inconsistentInstallation: return "已有安装文件不完整，请先恢复安装事务"
        case .recoveryRequired: return "安装恢复尚未完成，事务记录已保留"
        case .networkRecoveryRequired: return "检测到网络会话记录，请先恢复网络再更改服务"
        case .launchd(let message): return "服务管理失败：\(message)"
        }
    }
}

public struct InstallationPayload {
    public static let maximumBinaryBytes = 100 * 1024 * 1024
    let service: Data
    let recovery: Data
    let registration: ServiceRegistration

    /// Copy bytes before verifying. Only the staged, root-owned copy is ever
    /// installed/executed. The service digest is embedded in the signed installer.
    public static func prepare(app: URL, clientHash: String, uid: uid_t, serviceHash: String,
                               installer: URL, installerIdentity: CodeIdentity,
                               stagingPath: String, owner: uid_t) throws -> InstallationPayload {
        guard uid != 0, serviceHash.count == 64, serviceHash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw InstallationError.invalidPayload
        }
        let expected = try CodeIdentity(identifier: "dev.freev6.desktop", cdHash: clientHash)
        let staging = try SecureDirectory(path: stagingPath, owner: owner, create: true)
        let clientRoot = stagingPath + "/client.app"
        _ = try SecureDirectory(path: clientRoot, owner: owner, create: true)
        let contents = try SecureDirectory(path: clientRoot + "/Contents", owner: owner, create: true)
        let binaries = try SecureDirectory(path: clientRoot + "/Contents/MacOS", owner: owner, create: true)
        let info = try readSource(app.appendingPathComponent("Contents/Info.plist"), limit: 64 * 1024)
        guard let dictionary = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              dictionary["CFBundleExecutable"] as? String == "Flux6",
              dictionary["CFBundleIdentifier"] as? String == expected.identifier else { throw InstallationError.invalidPayload }
        try contents.write("Info.plist", data: info, mode: 0o600)
        try binaries.write("Flux6", data: readSource(app.appendingPathComponent("Contents/MacOS/Flux6"), limit: maximumBinaryBytes), mode: 0o700)
        // Only executable identity/entitlements are enrolled. Resources are never
        // trusted to select root executables; the independent service hash does that.
        let recovery = try readSource(installer, limit: maximumBinaryBytes)
        try staging.write("candidate-recovery", data: recovery, mode: 0o700)
        let recoveryIdentity = try CodeIdentity.protectedFile(at: URL(fileURLWithPath: stagingPath + "/candidate-recovery"), identifier: "dev.freev6.service-installer")
        guard recoveryIdentity == installerIdentity else { throw InstallationError.invalidPayload }
        let trustedSeal = try CodeIdentity.installerClientSeal(at: URL(fileURLWithPath: stagingPath + "/candidate-recovery"))
        let client = try CodeIdentity.protectedFile(at: URL(fileURLWithPath: clientRoot), identifier: expected.identifier, checkResources: false,
                                                    trustedClientSeal: trustedSeal)
        guard client == expected else { throw InstallationError.invalidPayload }
        let service = try readSource(app.appendingPathComponent("Contents/Library/LaunchServices/dev.freev6.network-service"), limit: maximumBinaryBytes)
        guard digest(service) == serviceHash else { throw InstallationError.invalidPayload }
        try staging.write("candidate-service", data: service, mode: 0o700)
        let serviceIdentity = try CodeIdentity.protectedFile(at: URL(fileURLWithPath: stagingPath + "/candidate-service"), identifier: ServiceProtocolVersion.machService)
        let registration = try ServiceRegistration(service: serviceIdentity, clients: [
            RegisteredClient(uid: uid, identity: client), RegisteredClient(uid: 0, identity: recoveryIdentity),
        ])
        return InstallationPayload(service: service, recovery: recovery, registration: registration)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func readSource(_ url: URL, limit: Int) throws -> Data {
        let file = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw InstallationError.invalidPayload }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw InstallationError.invalidPayload }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(file, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw InstallationError.invalidPayload }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw InstallationError.invalidPayload }
        }
    }
}

struct InstallationLayout {
    let helpers: String
    let daemons: String
    let data: String
    var state: String { data + "/installation" }
    static let system = InstallationLayout(helpers: "/Library/PrivilegedHelperTools", daemons: "/Library/LaunchDaemons",
                                           data: "/Library/Application Support/dev.freev6.desktop")
}

protocol ServiceControlling {
    func isLoaded() throws -> Bool
    func stop() throws
    func start(plist: String) throws
    func healthCheck(identity: CodeIdentity) throws
}

struct InstallationJournal: Codable {
    var schema = 1
    var committed = false
    let wasLoaded: Bool
    let previous: [String: Bool]
    let digests: [String: String]
}

/// A persistent transaction spanning the helper, launchd plist and registration.
/// No user-supplied destination, launchd label, arguments or executable is used.
final class ServiceInstaller {
    private let helpers: SecureDirectory
    private let daemons: SecureDirectory
    private let data: SecureDirectory
    private let state: SecureDirectory
    private let controller: ServiceControlling
    private let layout: InstallationLayout
    private let owner: uid_t
    private let installedIdentity: (URL, String) throws -> CodeIdentity
    private let slots = ["service", "recovery", "registration", "plist"]

    init(layout: InstallationLayout, owner: uid_t, controller: ServiceControlling,
         installedIdentity: @escaping (URL, String) throws -> CodeIdentity = {
             try CodeIdentity.protectedFile(at: $0, identifier: $1)
         }) throws {
        self.layout = layout
        self.owner = owner
        self.controller = controller
        self.installedIdentity = installedIdentity
        helpers = try SecureDirectory(path: layout.helpers, owner: owner, create: true, mode: 0o755)
        daemons = try SecureDirectory(path: layout.daemons, owner: owner)
        data = try SecureDirectory(path: layout.data, owner: owner, create: true, mode: 0o755)
        state = try SecureDirectory(path: layout.state, owner: owner, create: true)
    }

    private func location(_ slot: String) -> (SecureDirectory, String, mode_t) {
        switch slot {
        case "service": return (helpers, ServiceProtocolVersion.machService, 0o755)
        case "recovery": return (helpers, "dev.freev6.service-installer", 0o755)
        case "registration": return (data, "service-registration.json", 0o644)
        default: return (daemons, ServiceProtocolVersion.machService + ".plist", 0o644)
        }
    }

    private func current(_ slot: String) throws -> Data? {
        let (directory, name, _) = location(slot)
        return try directory.read(name, limit: InstallationPayload.maximumBinaryBytes)
    }

    private func put(_ slot: String, _ value: Data?) throws {
        let (directory, name, mode) = location(slot)
        if let value { try directory.write(name, data: value, mode: mode) }
        else { try directory.remove(name) }
    }

    private func launchDaemonPlist() throws -> Data {
        let plist: [String: Any] = ["Label": ServiceProtocolVersion.machService,
            "ProgramArguments": [layout.helpers + "/" + ServiceProtocolVersion.machService],
            "MachServices": [ServiceProtocolVersion.machService: true],
            "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background", "ThrottleInterval": 10,
            "AbandonProcessGroup": false]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func repairMissingLaunchDaemon() throws {
        guard try current("plist") == nil,
              try current("service") != nil, try current("recovery") != nil,
              let bytes = try current("registration") else { return }
        let registration = try ServiceRegistration.decode(bytes)
        let service = try installedIdentity(URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService),
                                            ServiceProtocolVersion.machService)
        guard registration.service == service else { throw RegistrationError.serviceIdentityMismatch }
        let recovery = try installedIdentity(URL(fileURLWithPath: layout.helpers + "/dev.freev6.service-installer"),
                                             "dev.freev6.service-installer")
        guard registration.clients.contains(where: { $0.uid == 0 && $0.identity == recovery }) else {
            throw RegistrationError.invalidClients
        }
        // This derived file can be rebuilt atomically without restarting a job.
        // Repair before the next snapshot so a failed upgrade can restart the old service.
        try put("plist", launchDaemonPlist())
    }

    private func journal(_ value: InstallationJournal) throws {
        try state.write("transaction.json", data: JSONEncoder().encode(value), mode: 0o600)
    }

    private func cleanup() throws {
        for slot in slots { try state.remove("previous-" + slot) }
        try state.remove("transaction.json")
    }

    private func restore(_ transaction: InstallationJournal) throws {
        try controller.stop()
        for slot in slots {
            if transaction.previous[slot] == true {
                guard let value = try state.read("previous-" + slot, limit: InstallationPayload.maximumBinaryBytes) else {
                    throw InstallationError.recoveryRequired
                }
                guard InstallationPayload.digest(value) == transaction.digests[slot] else { throw InstallationError.recoveryRequired }
                try put(slot, value)
            } else { try put(slot, nil) }
        }
        if transaction.wasLoaded {
            guard let value = try current("registration") else { throw InstallationError.recoveryRequired }
            let registration = try ServiceRegistration.decode(value)
            try controller.start(plist: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist")
            // A newer installer may not be enrolled in the previous service.
            // start() verifies launchd accepted it; the original app verifies XPC.
            guard registration.schema == ServiceRegistration.schemaVersion else { throw InstallationError.recoveryRequired }
        }
        var restored = transaction
        restored.committed = true
        try journal(restored)
        try cleanup()
    }

    private func recoverUnlocked() throws {
        guard let bytes = try state.read("transaction.json", limit: 4096) else { return }
        let transaction = try JSONDecoder().decode(InstallationJournal.self, from: bytes)
        guard transaction.schema == 1, Set(transaction.previous.keys) == Set(slots),
              Set(transaction.digests.keys) == Set(transaction.previous.filter { $0.value }.map(\.key)) else { throw InstallationError.recoveryRequired }
        if transaction.committed { try cleanup() }
        else { try restore(transaction) }
    }

    private func withNetworkLease<T>(_ body: () throws -> T) throws -> T {
        let lease: FileHandle
        do { lease = try data.acquireLock("network.lock") }
        catch ResourceStoreError.busy { throw InstallationError.busy }
        defer { try? lease.close() }
        guard try data.read("network-session.json", limit: 1024 * 1024) == nil else { throw InstallationError.networkRecoveryRequired }
        return try body()
    }

    func recover() throws {
        try state.withLock { try withNetworkLease {
            try recoverUnlocked()
            try repairMissingLaunchDaemon()
        } }
    }

    func install(_ payload: InstallationPayload) throws {
        try mutate { payload }
    }

    func installPreparing(_ prepare: () throws -> InstallationPayload) throws { try mutate(prepare) }

    func uninstall() throws { try mutate { nil } }

    private func mutate(_ prepare: () throws -> InstallationPayload?) throws {
        try state.withLock { try withNetworkLease {
            try recoverUnlocked()
            let payload = try prepare()
            try repairMissingLaunchDaemon()
            var previous: [String: Bool] = [:]
            var digests: [String: String] = [:]
            for slot in slots {
                let value = try current(slot)
                previous[slot] = value != nil
                if let value {
                    digests[slot] = InstallationPayload.digest(value)
                    try state.write("previous-" + slot, data: value, mode: 0o600)
                }
                else { try state.remove("previous-" + slot) }
            }
            let occupied = previous.values.filter { $0 }.count
            guard occupied == 0 || occupied == slots.count else { throw InstallationError.inconsistentInstallation }
            let proposedRegistration: ServiceRegistration?
            if let payload {
                var clients = payload.registration.clients
                if let bytes = try current("registration") {
                    let old = try ServiceRegistration.decode(bytes)
                    let replacedUsers = Set(clients.map(\.uid))
                    clients += old.clients.filter { !replacedUsers.contains($0.uid) }
                }
                proposedRegistration = try ServiceRegistration(service: payload.registration.service, clients: clients)
            } else { proposedRegistration = nil }
            var transaction = InstallationJournal(wasLoaded: try controller.isLoaded(), previous: previous, digests: digests)
            try journal(transaction)
            do {
                try controller.stop()
                if let payload {
                    try put("recovery", payload.recovery)
                    try put("service", payload.service)
                    try put("registration", JSONEncoder().encode(proposedRegistration!))
                    try put("plist", launchDaemonPlist())
                    try controller.start(plist: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist")
                    try controller.healthCheck(identity: payload.registration.service)
                } else {
                    for slot in slots { try put(slot, nil) }
                }
            } catch {
                do { try restore(transaction) }
                catch { throw InstallationError.recoveryRequired }
                throw error
            }
            // A failed commit fsync has an ambiguous on-disk outcome. Do not
            // begin rollback after writing a committed marker; either journal
            // version is safely recoverable while all backups remain intact.
            transaction.committed = true
            try journal(transaction)
            try cleanup()
        } }
    }
}

public enum SystemServiceInstaller {
    public static var stagingPath: String { InstallationLayout.system.state + "/payload" }

    public static func install(app: URL, clientHash: String, uid: uid_t, serviceHash: String,
                               installer: URL, installerIdentity: CodeIdentity) throws {
        guard geteuid() == 0 else { throw InstallationError.invalidPayload }
        let engine = try ServiceInstaller(layout: .system, owner: 0, controller: LaunchdController())
        try engine.installPreparing {
            try InstallationPayload.prepare(app: app, clientHash: clientHash, uid: uid, serviceHash: serviceHash,
                installer: installer, installerIdentity: installerIdentity, stagingPath: stagingPath, owner: 0)
        }
    }

    public static func uninstall() throws {
        guard geteuid() == 0 else { throw InstallationError.invalidPayload }
        try ServiceInstaller(layout: .system, owner: 0, controller: LaunchdController()).uninstall()
    }

    public static func recover() throws {
        guard geteuid() == 0 else { throw InstallationError.invalidPayload }
        try ServiceInstaller(layout: .system, owner: 0, controller: LaunchdController()).recover()
    }
}
