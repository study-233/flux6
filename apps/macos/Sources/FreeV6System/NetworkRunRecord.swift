import Darwin
import Foundation

/// v3 belongs only to a running core. The job label, disk paths, executable
/// and signal targets are always derived by the service, never from the record.
struct NetworkRunRecord: Codable, Equatable {
    enum Stage: String, Codable { case capturingDNS, registering, starting, applyingDNS, active, restoringDNS, stopping, exited, removed }
    let origin: ServiceProcessOrigin
    let ruleFiles: [String]
    var stage: Stage = .capturingDNS
    var revision: UInt64 = 1
    var tunnel: CoreTunnel?

    func validate(_ fields: [String: Any]) throws {
        let keys: Set<String> = ["origin", "ruleFiles", "stage", "revision"]
        guard Set(fields.keys) == (tunnel == nil ? keys : keys.union(["tunnel"])),
              let source = fields["origin"] as? [String: Any], Set(source.keys) == ["groupID", "bootID", "ownerUID"],
              origin.groupID > 1, revision > 0, revision < UInt64.max, ruleFiles.count <= 32,
              ruleFiles == Array(Set(ruleFiles)).sorted(), ruleFiles.allSatisfy(Self.validRuleFile) else {
            throw SessionStoreError.invalidRecord
        }
        switch stage {
        case .capturingDNS: guard revision == 1 else { throw SessionStoreError.invalidRecord }
        case .registering: guard revision >= 2 else { throw SessionStoreError.invalidRecord }
        case .starting: guard revision >= 3 else { throw SessionStoreError.invalidRecord }
        case .applyingDNS: guard revision >= 4 else { throw SessionStoreError.invalidRecord }
        case .active: guard revision >= 5 else { throw SessionStoreError.invalidRecord }
        case .restoringDNS, .stopping, .exited, .removed:
            guard revision >= 2 else { throw SessionStoreError.invalidRecord }
        }
        if let tunnel {
            guard let values = fields["tunnel"] as? [String: Any], Set(values.keys) == ["name", "index"],
                  tunnel.valid, stage != .capturingDNS, stage != .registering else { throw SessionStoreError.invalidRecord }
        } else if stage == .applyingDNS || stage == .active { throw SessionStoreError.invalidRecord }
    }

    static func validRuleFile(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 11 && name.hasPrefix("rule") && name.hasSuffix(".list")
            && bytes[4...5].allSatisfy { (48...57).contains($0) }
    }
}

protocol SessionRunNetwork {
    var controller: CoreController { get }
    func prepareDNS() throws
    func applyDNS() throws
    func restoreDNS() throws
    func ownedTunnel(pid: pid_t) throws -> CoreTunnel?
    func checkReadiness(pid: pid_t) throws -> CoreTunnel
    func verifyEgress(_ tunnel: CoreTunnel) throws
    func verifyRelease(_ tunnel: CoreTunnel) throws
}

struct SystemRunNetwork: SessionRunNetwork {
    let dns: SessionDNSTransaction
    let controller: CoreController
    private let job: ManagedCoreJob
    init(directory: SecureDirectory, job: ManagedCoreJob) throws {
        self.job = job
        dns = try SessionDNSTransaction(directory: directory, job: job)
        controller = try CoreController(directory: directory, job: job)
    }
    func prepareDNS() throws { try dns.prepare() }
    func applyDNS() throws { try dns.apply() }
    func restoreDNS() throws {
        _ = try dns.restore()
        guard try SystemDNSPreferences().resolverReleased() else { throw NetworkRunError.recoveryRequired }
    }
    func ownedTunnel(pid: pid_t) throws -> CoreTunnel? { try CoreTunnel.owned(by: pid) }
    func checkReadiness(pid: pid_t) throws -> CoreTunnel {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        try controller.waitUntilReady(timeout: 30)
        // The controller can also precede TUN creation. Wait for this job's
        // tunnel within the same readiness budget, without accepting a restart.
        while true {
            guard try job.status()?.pid == pid else { throw CoreControllerError.notRunning }
            if let tunnel = try ownedTunnel(pid: pid) { return tunnel }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw NetworkRunError.tunnelUnavailable }
            Thread.sleep(forTimeInterval: min(0.05, remaining))
        }
    }
    func verifyEgress(_ tunnel: CoreTunnel) throws {
        guard let pid = try job.status()?.pid else { throw CoreControllerError.notRunning }
        try tunnel.verifyEgress {
            guard try job.status()?.pid == pid, try ownedTunnel(pid: pid) == tunnel else {
                throw NetworkRunError.tunnelUnavailable
            }
        }
    }
    func verifyRelease(_ tunnel: CoreTunnel) throws { try tunnel.waitForRelease() }
}
