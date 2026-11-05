import Darwin
import Foundation
import SystemConfiguration

struct DNSBaseline: Codable {
    let serviceID: String
    let device: String
    let hardware: String
    let configuration: Data?

    init(id: String, device: String, hardware: String, dns: [String: Any]?) throws {
        serviceID = id
        self.device = device
        self.hardware = hardware
        configuration = try dns.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        _ = try dictionary()
    }

    func dictionary() throws -> [String: Any]? {
        guard UUID(uuidString: serviceID) != nil, DNSResolverPolicy.validDevice(device),
              ["Ethernet", "AirPort"].contains(hardware) else { throw SessionDNSError.invalidRecord }
        guard let configuration else { return nil }
        guard configuration.count <= 65_536,
              let value = try PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
              value[kSCResvLink as String] == nil, value[kSCResvInactive as String] == nil,
              value[kSCPropNetDNSSupplementalMatchDomains as String] == nil,
              value[kSCPropNetDNSSupplementalMatchOrders as String] == nil else { throw SessionDNSError.invalidRecord }
        return value
    }
}

struct DNSRecoveryResult: Codable, Equatable {
    var externalChanges: [String] = []
    var removedServices: [String] = []
}

struct SessionDNSRecord: Codable {
    enum Phase: String, Codable { case prepared, applying, applied, restoring, restored }
    let schema: Int
    let sessionID: UUID
    let networkSetID: String
    let targets: [DNSBaseline]
    var phase: Phase
    var result: DNSRecoveryResult?

    func validate(for sessionID: UUID) throws {
        guard schema == 1, self.sessionID == sessionID, UUID(uuidString: networkSetID) != nil,
              (1...2).contains(targets.count) else { throw SessionDNSError.invalidRecord }
        let ids = Set(targets.map(\.serviceID))
        guard ids.count == targets.count else { throw SessionDNSError.invalidRecord }
        for entry in targets {
            let base = try entry.dictionary()
            guard try !DNSResolverPolicy.referencesEndpoint(base) else {
                throw SessionDNSError.invalidRecord
            }
        }
        guard (phase == .restored) == (result != nil) else { throw SessionDNSError.invalidRecord }
        if let result {
            let reports = result.externalChanges + result.removedServices
            guard reports.count == Set(reports).count, Set(reports).isSubset(of: ids) else { throw SessionDNSError.invalidRecord }
        }
    }
}

/// Journal in the service-owned UUID workspace. Its parent network session
/// must retain the installation-shared lease until DNS recovery and core exit.
final class SessionDNSTransaction {
    static let journalName = "dns-transaction.plist"
    private let directory: SecureDirectory
    private let sessionID: UUID
    private let access: any SessionDNSPreferences

    private let requireReady: () throws -> Void
    private let requireEffective: ([DNSBaseline]) throws -> Void

    init(directory: SecureDirectory, job: ManagedCoreJob) throws {
        let sessionID = job.sessionID
        guard directory.owner == 0, geteuid() == 0,
              directory.path == ServiceConfigurationAssembler.sessions + "/" + sessionID.uuidString else {
            throw SessionDNSError.wrongSession
        }
        _ = try ServiceProcessOrigin.current()
        try directory.requirePrivate()
        self.directory = directory
        self.sessionID = sessionID
        access = SystemDNSPreferences()
        requireEffective = { try SystemResolverCheck.verify(sessionID: sessionID, devices: $0.map(\.device)) }
        requireReady = {
            try CoreDNSListener.waitUntilReady(port: DNSResolverPolicy.port, sessionID: sessionID) { try job.status()?.pid }
        }
    }

    #if DEBUG
    init(isolated directory: SecureDirectory, sessionID: UUID, preferences: any SessionDNSPreferences,
         requireReady: @escaping () throws -> Void = {}, requireEffective: @escaping ([DNSBaseline]) throws -> Void = { _ in }) throws {
        guard geteuid() != 0, directory.owner == geteuid(),
              URL(fileURLWithPath: directory.path).lastPathComponent == sessionID.uuidString else {
            throw SessionDNSError.wrongSession
        }
        try directory.requirePrivate()
        self.directory = directory
        self.sessionID = sessionID
        access = preferences
        self.requireReady = requireReady
        self.requireEffective = requireEffective
    }
    #endif

    /// Capture before launching the core, so the physical IPv4/IPv6 primary
    /// services and any DHCP absence belong to the original network.
    func prepare() throws {
        guard try access.resolverReleased() else { throw SessionDNSError.unsupportedNetwork }
        try access.withLock { prefs in
            guard try load() == nil else { throw SessionDNSError.invalidPhase }
            let (setID, targets) = try Self.targets(in: prefs, primary: access.primaryServices())
            try persist(SessionDNSRecord(schema: 1, sessionID: sessionID, networkSetID: setID,
                                         targets: targets, phase: .prepared))
        }
    }

    /// Verify listeners before taking the preferences lock for the short write.
    func apply() throws {
        try requireReady()
        var wroteIntent = false
        do {
            let targets = try access.withLock { prefs in
                guard var record = try load(), record.phase == .prepared else { throw SessionDNSError.invalidPhase }
                let (setID, current) = try Self.targets(in: prefs, primary: access.primaryServices())
                guard setID == record.networkSetID, current.count == record.targets.count else { throw SessionDNSError.changed }
                for (expected, actual) in zip(record.targets, current) {
                    guard expected.serviceID == actual.serviceID, expected.device == actual.device, expected.hardware == actual.hardware,
                          try Self.equal(expected.dictionary(), actual.dictionary()) else { throw SessionDNSError.changed }
                }
                for target in record.targets {
                    try DNSNetworkService.write(DNSResolverPolicy.configured(try target.dictionary()), id: target.serviceID, in: prefs)
                }
                record.phase = .applying
                try persist(record)
                wroteIntent = true
                try access.commit(prefs)
                try access.apply(prefs)
                return record.targets
            }
            // Let configd process the activation outside its preferences lock.
            try requireEffective(targets)
            try access.withLock { prefs in
                guard var record = try load(), record.phase == .applying else { throw SessionDNSError.invalidPhase }
                let expectedPrimary = Dictionary(uniqueKeysWithValues: targets.map { ($0.serviceID, $0.device) })
                guard try access.primaryServices() == expectedPrimary, let set = SCNetworkSetCopyCurrent(prefs),
                      SCNetworkSetGetSetID(set) as String? == record.networkSetID else { throw SessionDNSError.changed }
                let services = try DNSNetworkService.services(prefs)
                for target in record.targets {
                    guard let service = try DNSNetworkService.read(target.serviceID, from: services),
                          service.type == "Ethernet", service.device == target.device, service.hardware == target.hardware,
                          try Self.equal(service.dns, DNSResolverPolicy.configured(target.dictionary())) else {
                        throw SessionDNSError.applyFailed
                    }
                }
                record.phase = .applied
                try persist(record)
            }
        } catch {
            if wroteIntent { _ = try restore() }
            throw error
        }
    }

    /// Safe after restart or a commit/apply acknowledgement loss. Restore the
    /// address+port pair only while it still matches our written pair. Merge
    /// unrelated edits, including search domains and DNS enablement changes.
    func restore() throws -> DNSRecoveryResult {
        let pending = try access.withLock { prefs in
            guard var record = try load() else { throw SessionDNSError.invalidRecord }
            if record.phase == .restored { return record }
            if record.phase == .prepared {
                record.phase = .restored
                record.result = DNSRecoveryResult()
                try persist(record)
                return record
            }
            let services = try DNSNetworkService.services(prefs)
            var changed = false
            for target in record.targets {
                guard let service = try DNSNetworkService.read(target.serviceID, from: services) else { continue }
                let base = try target.dictionary()
                let current = DNSResolverPolicy.resolverFields(service.dns)
                guard current == DNSResolverPolicy.resolverFields(DNSResolverPolicy.configured(base)) else { continue }
                guard service.type == "Ethernet", service.device == target.device, service.hardware == target.hardware else {
                    throw SessionDNSError.identityChanged
                }
                var restored = service.dns ?? [:]
                for key in [DNSResolverPolicy.addressesKey, DNSResolverPolicy.portKey] { restored[key] = base?[key] }
                try DNSNetworkService.write(restored.isEmpty && base == nil ? nil : restored, id: target.serviceID, in: prefs)
                changed = true
            }
            record.phase = .restoring
            try persist(record)
            if changed { try access.commit(prefs) }
            // The prior process could have committed and died before applying.
            try access.apply(prefs)
            return record
        }
        if let result = pending.result { return result }

        // A commit acknowledgement can precede configd publishing the new
        // resolvers. Keep the journal and core until consumers can switch.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while try !access.resolverReleased() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SessionDNSError.applyFailed }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return try access.withLock { prefs in
            guard var record = try load(), record.phase == .restoring else { throw SessionDNSError.invalidPhase }
            let services = try DNSNetworkService.services(prefs)
            var result = DNSRecoveryResult()
            for target in record.targets {
                guard let service = try DNSNetworkService.read(target.serviceID, from: services) else {
                    result.removedServices.append(target.serviceID)
                    continue
                }
                guard try !DNSResolverPolicy.referencesEndpoint(service.dns) else { throw SessionDNSError.applyFailed }
                if try DNSResolverPolicy.resolverFields(service.dns) != DNSResolverPolicy.resolverFields(target.dictionary()) {
                    result.externalChanges.append(target.serviceID)
                }
            }
            record.phase = .restored
            record.result = result
            try persist(record)
            return result
        }
    }

    static func targets(in prefs: SCPreferences, primary: [String: String]) throws -> (String, [DNSBaseline]) {
        guard (1...2).contains(primary.count), let set = SCNetworkSetCopyCurrent(prefs),
              let setID = SCNetworkSetGetSetID(set) as String?, UUID(uuidString: setID) != nil,
              let members = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw SessionDNSError.unsupportedNetwork }
        let services = try DNSNetworkService.services(prefs)
        var result: [DNSBaseline] = []
        for (id, device) in primary.sorted(by: { $0.key < $1.key }) {
            guard UUID(uuidString: id) != nil, DNSResolverPolicy.validDevice(device),
                  let member = members.first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }),
                  SCNetworkServiceGetEnabled(member), let service = try DNSNetworkService.read(id, from: services),
                  service.type == "Ethernet", service.device == device, let hardware = service.hardware, ["Ethernet", "AirPort"].contains(hardware),
                  service.dns?[kSCResvInactive as String] == nil, service.dns?[kSCPropNetDNSSupplementalMatchDomains as String] == nil,
                  service.dns?[kSCPropNetDNSSupplementalMatchOrders as String] == nil,
                  try !DNSResolverPolicy.referencesEndpoint(service.dns)
            else { throw SessionDNSError.unsupportedNetwork }
            result.append(try DNSBaseline(id: id, device: device, hardware: hardware, dns: service.dns))
        }
        return (setID, result)
    }

    private static func equal(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as NSDictionary) == (b as NSDictionary)
        default: return false
        }
    }

    private func load() throws -> SessionDNSRecord? {
        try directory.requirePrivate()
        try directory.requirePrivateFile(Self.journalName)
        guard let bytes = try directory.read(Self.journalName, limit: 262_144) else { return nil }
        do {
            guard let fields = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
                throw SessionDNSError.invalidRecord
            }
            let keys: Set<String> = ["schema", "sessionID", "networkSetID", "targets", "phase"]
            guard Set(fields.keys) == (fields["result"] == nil ? keys : keys.union(["result"])),
                  let entries = fields["targets"] as? [[String: Any]], (1...2).contains(entries.count),
                  entries.allSatisfy({ entry in
                      let required: Set<String> = ["serviceID", "device", "hardware"]
                      return Set(entry.keys) == (entry["configuration"] == nil ? required : required.union(["configuration"]))
                  }) else { throw SessionDNSError.invalidRecord }
            if let result = fields["result"] {
                guard let result = result as? [String: Any], Set(result.keys) == ["externalChanges", "removedServices"] else {
                    throw SessionDNSError.invalidRecord
                }
            }
            let record = try PropertyListDecoder().decode(SessionDNSRecord.self, from: bytes)
            try record.validate(for: sessionID)
            return record
        } catch { throw SessionDNSError.invalidRecord }
    }

    private func persist(_ record: SessionDNSRecord) throws {
        try record.validate(for: sessionID)
        let bytes = try PropertyListEncoder().encode(record)
        guard bytes.count <= 262_144 else { throw SessionDNSError.invalidRecord }
        try directory.requirePrivateFile(Self.journalName)
        try directory.write(Self.journalName, data: bytes, mode: 0o600)
        try directory.requirePrivateFile(Self.journalName)
    }
}
