#if DEBUG
import Darwin
import Foundation
import SystemConfiguration

/// Ordinary-user launchd integration host. Only the system DNS backing store,
/// interface and egress are substituted. The same coordinator, controller,
/// DNS transaction, real core job, private workspace and lease are exercised.
public enum NetworkRunProbe {
    public static func run(path: String, request: Data?, checkpoint: String?) throws {
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        let data = try SecureDirectory(path: path, owner: geteuid())
        let store = try PreparedSessionStore(path: path, owner: geteuid())
        try configure(store, data: data)
        if let checkpoint {
            store.checkCheckpoint = { name in
                guard name == checkpoint else { return }
                guard let bytes = try? data.read(PreparedSessionStore.journalName, limit: 4096) else { exit(2) }
                FileHandle.standardOutput.write(bytes + Data([10]))
                DispatchSemaphore(value: 0).wait()
            }
        }
        guard let request else { try store.recoverInterruptedSession(); return }
        let resources = try ServiceResourceStore(path: path + "/resources", owner: geteuid())
        let prepared = try resources.prepareSession(request, clientUID: geteuid(), sessions: store)
        let active = try store.startRunning(sessionID: prepared.sessionID, clientUID: geteuid())
        guard let run = active.run, run.stage == .active else { throw SessionStoreError.invalidTransition }
        do {
            try store.stopRunning(sessionID: active.sessionID, clientUID: geteuid() + 1, revision: run.revision)
            throw ServiceMessageError.invalid
        } catch SessionStoreError.wrongOwner {}
        do {
            try store.stopRunning(sessionID: active.sessionID, clientUID: geteuid(), revision: run.revision - 1)
            throw ServiceMessageError.invalid
        } catch SessionStoreError.invalidTransition {}
        do { try store.recoverInterruptedSession(); throw ServiceMessageError.invalid }
        catch SessionStoreError.occupied {}
        for _ in 0..<2 { try store.stopRunning(sessionID: active.sessionID, clientUID: geteuid(), revision: run.revision) }
    }

    static func configure(_ store: PreparedSessionStore, data: SecureDirectory) throws {
        let prefs = try RunProbePreferences(data)
        store.probeNetwork = { try RunProbeNetwork(directory: $0, job: $1, prefs: prefs) }
        store.probeConfiguration = { full, _ in
            guard let root = try JSONSerialization.jsonObject(with: full) as? [String: Any],
                  var dns = root["dns"] as? [String: Any], let hosts = root["hosts"],
                  let socket = root["external-controller-unix"] else { throw ServiceMessageError.invalid }
            dns["listen"] = "127.0.0.1:" + String(prefs.port)
            dns.removeValue(forKey: "nameserver-policy")
            dns["default-nameserver"] = ["127.0.0.1"]
            dns["proxy-server-nameserver"] = ["tcp://127.0.0.1:1"]
            dns["nameserver"] = ["tcp://127.0.0.1:1"]
            var isolated: [String: Any] = ["mode": "direct", "log-level": "error", "tun": ["enable": false],
                "mixed-port": 0, "port": 0, "dns": dns, "hosts": hosts, "external-controller-unix": socket,
                "rule-providers": ["rule01": ["type": "inline", "behavior": "classical", "payload": ["DOMAIN,example.test"]]],
                "rules": ["MATCH,DIRECT"]]
            if let port = prefs.healthPort {
                isolated["proxies"] = [
                    ["name": "本地 A", "type": "direct"], ["name": "本地 B", "type": "direct"],
                    ["name": "慢速探针", "type": "http", "server": "127.0.0.1", "port": port]
                ]
                isolated["proxy-groups"] = [
                    ["name": SessionNodeGroup.access.coreName, "type": "url-test", "proxies": ["本地 A", "本地 B", "REJECT"],
                     "url": "http://127.0.0.1:" + String(port), "interval": 86400, "lazy": false],
                    ["name": SessionNodeGroup.chain.coreName, "type": "select", "proxies": ["REJECT", "DIRECT", "慢速探针"]]
                ]
            }
            return try JSONSerialization.data(withJSONObject: isolated, options: .withoutEscapingSlashes)
        }

    }
}

private struct RunProbeNetwork: SessionRunNetwork {
    let dns: SessionDNSTransaction
    let controller: CoreController
    let job: ManagedCoreJob
    let prefs: RunProbePreferences
    let simulated = CoreTunnel(name: "utun999999", index: 999999)
    init(directory: SecureDirectory, job: ManagedCoreJob, prefs: RunProbePreferences) throws {
        self.job = job
        self.prefs = prefs
        controller = try CoreController(probeDirectory: directory) {
            guard let pid = try job.status()?.pid else { throw CoreControllerError.notRunning }
            return pid
        }
        dns = try SessionDNSTransaction(isolated: directory, sessionID: job.sessionID, preferences: prefs, requireReady: {
            try CoreDNSListener.waitUntilReady(port: prefs.port, sessionID: job.sessionID) { try job.status()?.pid }
        }, requireEffective: { _ in
            guard try !prefs.resolverReleased() else { throw SessionDNSError.applyFailed }
        })
    }
    func prepareDNS() throws { try dns.prepare() }
    func applyDNS() throws { try dns.apply() }
    func restoreDNS() throws {
        if try prefs.data.read("block-dns-recovery", limit: 64) != nil { throw SessionDNSError.applyFailed }
        _ = try dns.restore()
    }
    func ownedTunnel(pid: pid_t) throws -> CoreTunnel? {
        try job.status()?.pid == pid ? simulated : nil
    }
    func checkReadiness(pid: pid_t) throws -> CoreTunnel {
        try controller.waitUntilReady()
        guard try CoreTunnel.owned(by: pid) == nil else { throw NetworkRunError.tunnelUnavailable }
        return simulated
    }
    func verifyEgress(_ tunnel: CoreTunnel) throws {
        guard try prefs.data.read("reject-egress", limit: 64) == nil else { throw NetworkRunError.egressUnavailable }
        _ = try controller.version()
    }
    func verifyRelease(_ tunnel: CoreTunnel) throws {
        guard tunnel == simulated, try job.status()?.pid == nil, try prefs.resolverReleased() else {
            throw NetworkRunError.recoveryRequired
        }
    }
}

private final class RunProbePreferences: SessionDNSPreferences {
    let data: SecureDirectory
    let port: Int
    let serviceID: String
    let healthPort: Int?
    private let filename = "probe-preferences.plist"
    private let lock = NSLock()

    init(_ directory: SecureDirectory) throws {
        guard geteuid() != 0, directory.owner == geteuid(),
              let info = try directory.read("probe-options.json", limit: 1024),
              let fields = try JSONSerialization.jsonObject(with: info) as? [String: Any],
              let port = fields["port"] as? Int, (1024...65535).contains(port),
              let id = fields["serviceID"] as? String, UUID(uuidString: id) != nil else { throw ServiceMessageError.invalid }
        data = directory
        self.port = port
        healthPort = (fields["healthPort"] as? Int).flatMap { (1024...65535).contains($0) ? $0 : nil }
        serviceID = id
    }

    func primaryServices() throws -> [String: String] { [serviceID: "en0"] }
    func resolverReleased() throws -> Bool {
        try withLock { prefs in
            let service = try DNSNetworkService.read(serviceID, from: DNSNetworkService.services(prefs))
            return try !DNSResolverPolicy.referencesEndpoint(service?.dns)
        }
    }
    func withLock<T>(_ body: (SCPreferences) throws -> T) throws -> T {
        guard lock.try() else { throw SessionDNSError.busy }
        defer { lock.unlock() }
        // Always pass a full fixture filename. No call opens the system preferences.
        guard let prefs = SCPreferencesCreate(nil, "FreeV6 run fixture" as CFString,
            (data.path + "/" + filename) as CFString) else { throw SessionDNSError.unavailable }
        SCPreferencesSynchronize(prefs)
        return try body(prefs)
    }
    func commit(_ preferences: SCPreferences) throws {
        guard let keys = SCPreferencesCopyKeyList(preferences) as? [String] else { throw SessionDNSError.commitFailed }
        var fields: [String: Any] = [:]
        for key in keys { fields[key] = SCPreferencesGetValue(preferences, key as CFString) }
        try data.write(filename, data: PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0), mode: 0o600)
    }
    func apply(_ preferences: SCPreferences) throws {} // No call to configd.
}
#endif
