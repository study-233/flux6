import Darwin
import Foundation
import SystemConfiguration
import FreeV6Configuration
import XCTest
@testable import FreeV6System

/// Uses a fresh SCPreferences session over an actual private file each time.
/// macOS requires an administrator even to SCPreferencesLock a custom plist.
/// Only the lock, commit and activation boundary is simulated here.
private final class IsolatedDNSPreferences: SessionDNSPreferences {
    let file: URL
    let setID = UUID().uuidString
    let first = UUID().uuidString
    let second = UUID().uuidString
    let other = UUID().uuidString
    var primary: [String: String] = [:]
    var commits = 0
    var activations = 0
    var failBeforeCommit = false
    var failAfterCommit = false
    var failApply = false
    var publishedRelease: () throws -> Bool = { true }
    var crashAfterCommit = false
    private let lock = NSLock()

    init(root: URL, initial: [String: Any]?, secondDNS: [String: Any]? = nil) throws {
        file = root.appendingPathComponent("preferences.plist")
        primary = [first: "en0", second: "en1"]
        var services: [String: Any] = [:], links: [String: Any] = [:]
        for (id, device, dns) in [(first, "en0", initial), (second, "en1", secondDNS), (other, "en2", ["ServerAddresses": ["192.0.2.99"]])] {
            var service: [String: Any] = ["Interface": ["Type": "Ethernet", "DeviceName": device, "Hardware": "Ethernet"], "UserDefinedName": device]
            service["DNS"] = dns
            services[id] = service
            links[id] = ["__LINK__": "/NetworkServices/" + id]
        }
        try save(["CurrentSet": "/Sets/" + setID, "Sets": [setID: ["Network": ["Service": links]]], "NetworkServices": services])
    }

    init(reopening root: URL, primary: [String: String]) {
        file = root.appendingPathComponent("preferences.plist")
        self.primary = primary
    }

    private func save(_ root: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: file, options: .atomic)
    }

    func withLock<T>(_ body: (SCPreferences) throws -> T) throws -> T {
        guard lock.try() else { throw SessionDNSError.busy }
        defer { lock.unlock() }
        let prefs = try XCTUnwrap(SCPreferencesCreate(nil, "FreeV6 isolated fixture" as CFString, file.path as CFString))
        SCPreferencesSynchronize(prefs)
        return try body(prefs)
    }

    func resolverReleased() throws -> Bool { try publishedRelease() }

    func primaryServices() throws -> [String: String] { primary }

    func commit(_ preferences: SCPreferences) throws {
        if failBeforeCommit { throw SessionDNSError.commitFailed }
        let keys = try XCTUnwrap(SCPreferencesCopyKeyList(preferences) as? [String])
        var root: [String: Any] = [:]
        for key in keys { root[key] = SCPreferencesGetValue(preferences, key as CFString) }
        try save(root)
        commits += 1
        if crashAfterCommit { Darwin.kill(getpid(), SIGKILL) }
        if failAfterCommit { throw SessionDNSError.commitFailed }
    }

    func apply(_ preferences: SCPreferences) throws {
        if failApply { throw SessionDNSError.applyFailed }
        activations += 1
    }

    func changeService(_ id: String, _ transform: (inout [String: Any]?) -> Void) throws {
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        var services = try XCTUnwrap(root["NetworkServices"] as? [String: Any])
        var service = services[id] as? [String: Any]
        transform(&service)
        services[id] = service
        root["NetworkServices"] = services
        try save(root)
    }

    func dns(_ id: String) throws -> NSDictionary? {
        try withLock { prefs in try DNSNetworkService.read(id, from: DNSNetworkService.services(prefs))?.dns as NSDictionary? }
    }
}

final class SessionDNSTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture(initial: [String: Any]? = nil,
                         _ body: (IsolatedDNSPreferences, SecureDirectory, UUID) throws -> Void) throws {
        guard geteuid() != 0 else { throw XCTSkip("DNS fixtures must run as ordinary user") }
        let id = UUID(), url = repository.appendingPathComponent("build/dns-tests/" + id.uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = try IsolatedDNSPreferences(root: url, initial: initial, secondDNS: [:])
        try body(prefs, SecureDirectory(path: url.path, owner: geteuid()), id)
    }

    func testDualPrimaryRoundTripPreservesAbsenceExplicitEmptyAndUnselectedServices() throws {
        try fixture { prefs, dir, id in
            let transaction = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            try transaction.prepare()
            XCTAssertThrowsError(try transaction.prepare())
            try transaction.apply()
            let loopback: NSDictionary = ["ServerAddresses": ["127.0.0.1"], "ServerPort": 1053]
            XCTAssertEqual(try prefs.dns(prefs.first), loopback)
            XCTAssertEqual(try prefs.dns(prefs.second), loopback)
            XCTAssertEqual(try prefs.dns(prefs.other), ["ServerAddresses": ["192.0.2.99"]])
            try dir.requirePrivateFile(SessionDNSTransaction.journalName)
            let fresh = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            XCTAssertEqual(try fresh.restore(), DNSRecoveryResult())
            XCTAssertNil(try prefs.dns(prefs.first))
            XCTAssertEqual(try prefs.dns(prefs.second), [:])
            XCTAssertEqual(try fresh.restore(), DNSRecoveryResult())
            XCTAssertEqual(prefs.commits, 2)
            XCTAssertEqual(prefs.activations, 2)
            XCTAssertThrowsError(try fresh.apply())
        }
    }

    func testRestoreOnlyOwnedPairAndPreserveExternalResolverAndSearchEdits() throws {
        let manual: [String: Any] = ["ServerAddresses": ["2001:db8::11"], "ServerPort": 5353, "SearchDomains": ["original.test"]]
        try fixture(initial: manual) { prefs, dir, id in
            let transaction = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            try transaction.prepare()
            try transaction.apply()
            let external = ["ServerAddresses": ["192.0.2.44"], "ServerPort": 9953] as [String: Any]
            try prefs.changeService(prefs.second) { $0?["DNS"] = external }
            try prefs.changeService(prefs.first) { service in
                service?["UserDefinedName"] = "Renamed"
                var dns = service?["DNS"] as! [String: Any]
                dns["SearchDomains"] = ["changed.test"]
                service?["DNS"] = dns
            }
            prefs.primary = [prefs.other: "en2"]
            XCTAssertEqual(try transaction.restore().externalChanges, [prefs.second])
            var expected = manual
            expected["SearchDomains"] = ["changed.test"]
            XCTAssertEqual(try prefs.dns(prefs.first), expected as NSDictionary)
            XCTAssertEqual(try prefs.dns(prefs.second), external as NSDictionary)
        }
    }

    func testPreparationAndResolverGateDoNotModifyChangedNetwork() throws {
        try fixture { prefs, dir, id in
            let transaction = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs,
                requireReady: { throw SessionDNSError.resolverUnavailable })
            try transaction.prepare()
            XCTAssertThrowsError(try transaction.apply()) { XCTAssertEqual($0 as? SessionDNSError, .resolverUnavailable) }
            let fresh = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            try prefs.changeService(prefs.first) { $0?["DNS"] = ["SearchDomains": ["changed.test"]] }
            XCTAssertThrowsError(try fresh.apply()) { XCTAssertEqual($0 as? SessionDNSError, .changed) }
            prefs.primary = [prefs.other: "en2"]
            XCTAssertThrowsError(try fresh.apply())
            XCTAssertEqual(try fresh.restore(), DNSRecoveryResult())
            XCTAssertEqual(prefs.commits, 0)
            XCTAssertEqual(prefs.activations, 0)
        }
        for dns in [["__INACTIVE__": true], ["SupplementalMatchDomains": ["corp.test"]],
                    ["ServerAddresses": ["127.0.0.1"], "ServerPort": 1053]] as [[String: Any]] {
            try fixture(initial: dns) { prefs, dir, id in
                XCTAssertThrowsError(try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs).prepare())
                XCTAssertNil(try dir.read(SessionDNSTransaction.journalName, limit: 262_144))
            }
        }
        try fixture { prefs, dir, id in
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            for primary in [[:], [prefs.first: "utun3"], [prefs.first: "en9"], [UUID().uuidString: "en0"]] {
                prefs.primary = primary
                XCTAssertThrowsError(try tx.prepare())
            }
        }
    }

    func testRecoverAfterWriteBeforeCommitAfterCommitAndAfterFailedActivation() throws {
        for point in ["before", "after", "activation"] {
            try fixture { prefs, dir, id in
                func fresh() throws -> SessionDNSTransaction { try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs) }
                try fresh().prepare()
                prefs.failBeforeCommit = point == "before"
                prefs.failAfterCommit = point == "after"
                prefs.failApply = point == "activation"
                XCTAssertThrowsError(try fresh().apply())
                XCTAssertNil(try prefs.dns(prefs.first)) // Observed failures immediately attempt rollback.
                prefs.failBeforeCommit = false; prefs.failAfterCommit = false; prefs.failApply = false
                XCTAssertEqual(try fresh().restore(), DNSRecoveryResult())
                XCTAssertNil(try prefs.dns(prefs.first))
                XCTAssertEqual(try prefs.dns(prefs.second), [:])
                XCTAssertEqual(prefs.activations, 1)
            }
        }
    }

    func testFailedEffectiveResolutionRollsBackAndPreservesChangesDuringActivation() throws {
        try fixture { prefs, dir, id in
            let external: NSDictionary = ["ServerAddresses": ["192.0.2.81"]]
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs, requireEffective: { _ in
                // An unrelated writer can acquire the preferences lock while the
                // system resolver is being checked. Its edit must survive rollback.
                try prefs.withLock { _ in try prefs.changeService(prefs.second) { $0?["DNS"] = external } }
                throw SessionDNSError.applyFailed
            })
            try tx.prepare()
            XCTAssertThrowsError(try tx.apply()) { XCTAssertEqual($0 as? SessionDNSError, .applyFailed) }
            XCTAssertNil(try prefs.dns(prefs.first))
            XCTAssertEqual(try prefs.dns(prefs.second), external)
            XCTAssertEqual(try tx.restore().externalChanges, [prefs.second])
        }
    }

    func testRestoreReappliesAfterCommitLossAndReportsRemovedService() throws {
        try fixture { prefs, dir, id in
            func fresh() throws -> SessionDNSTransaction { try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs) }
            try fresh().prepare()
            try fresh().apply()
            try prefs.changeService(prefs.second) { $0 = nil }
            prefs.failAfterCommit = true
            XCTAssertThrowsError(try fresh().restore())
            XCTAssertNil(try prefs.dns(prefs.first))
            prefs.failAfterCommit = false
            let commits = prefs.commits
            XCTAssertEqual(try fresh().restore().removedServices, [prefs.second])
            XCTAssertEqual(prefs.commits, commits)
            XCTAssertEqual(prefs.activations, 2)
        }
    }

    func testInterruptedPublicationRetainsRollbackAndRechecksExternalChanges() throws {
        try fixture { prefs, dir, id in
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            prefs.publishedRelease = { false }
            XCTAssertThrowsError(try tx.prepare())
            prefs.publishedRelease = { true }
            try tx.prepare()
            try tx.apply()
            prefs.publishedRelease = { throw SessionDNSError.unavailable }
            XCTAssertThrowsError(try tx.restore())
            let pending = try PropertyListDecoder().decode(SessionDNSRecord.self,
                from: XCTUnwrap(dir.read(SessionDNSTransaction.journalName, limit: 262_144)))
            XCTAssertEqual(pending.phase, .restoring)
            XCTAssertNil(try prefs.dns(prefs.first))

            var observations = 0
            prefs.publishedRelease = {
                observations += 1
                if observations == 1 { return false }
                try prefs.withLock { _ in
                    try prefs.changeService(prefs.second) { $0?["DNS"] = ["ServerAddresses": ["192.0.2.200"]] }
                }
                return true
            }
            let restarted = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            XCTAssertEqual(try restarted.restore().externalChanges, [prefs.second])
            XCTAssertEqual(observations, 2)
            XCTAssertEqual(prefs.commits, 2)
        }
    }

    func testMixedResolverListsCannotBeClaimedOrSilentlyAbandoned() throws {
        let mixed: [String: Any] = ["ServerAddresses": ["192.0.2.200", "127.0.0.1"], "ServerPort": 1053]
        try fixture(initial: mixed) { prefs, dir, id in
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            XCTAssertThrowsError(try tx.prepare())
            XCTAssertEqual(prefs.commits, 0)
        }
        try fixture { prefs, dir, id in
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            try tx.prepare()
            try tx.apply()
            try prefs.changeService(prefs.second) { $0?["DNS"] = mixed }
            XCTAssertThrowsError(try tx.restore()) { XCTAssertEqual($0 as? SessionDNSError, .applyFailed) }
            XCTAssertEqual(try prefs.dns(prefs.second), mixed as NSDictionary)
            try prefs.changeService(prefs.second) { $0?["DNS"] = ["ServerAddresses": ["192.0.2.200"]] }
            XCTAssertEqual(try tx.restore().externalChanges, [prefs.second])
        }
    }

    func testRestoringRejectsReusedServiceIdentityAndDamagedOrForeignRecords() throws {
        try fixture { prefs, dir, id in
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            try tx.prepare(); try tx.apply()
            try prefs.changeService(prefs.second) { $0?["Interface"] = ["Hardware": "Ethernet", "DeviceName": "en7"] }
            XCTAssertThrowsError(try tx.restore()) { XCTAssertEqual($0 as? SessionDNSError, .identityChanged) }
            XCTAssertEqual(try prefs.dns(prefs.first)?["ServerPort"] as? Int, 1053)
            let name = SessionDNSTransaction.journalName
            let original = try XCTUnwrap(dir.read(name, limit: 262_144))
            var tree = try XCTUnwrap(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
            tree["sessionID"] = UUID().uuidString
            try dir.write(name, data: PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0), mode: 0o600)
            XCTAssertThrowsError(try tx.restore()) { XCTAssertEqual($0 as? SessionDNSError, .invalidRecord) }
            try dir.write(name, data: Data([1, 2, 3]), mode: 0o600)
            XCTAssertThrowsError(try tx.restore())
            XCTAssertEqual(try dir.read(name, limit: 262_144), Data([1, 2, 3]))
            XCTAssertEqual(prefs.commits, 1)
        }
    }

    func testFreshProcessRecoversAfterSIGKILLAtDNSCommitAndRollbackCommit() throws {
        let env = ProcessInfo.processInfo.environment
        if let value = env["FREEV6_DNS_CRASH_FIXTURE"] {
            let id = try XCTUnwrap(UUID(uuidString: value))
            let root = repository.appendingPathComponent("build/dns-tests/" + id.uuidString)
            let directory = try SecureDirectory(path: root.path, owner: geteuid())
            let primary = try JSONDecoder().decode([String: String].self,
                from: XCTUnwrap(directory.read("test-primary.json", limit: 1024)))
            let isolated = IsolatedDNSPreferences(reopening: root, primary: primary)
            let tx = try SessionDNSTransaction(isolated: directory, sessionID: id, preferences: isolated)
            isolated.crashAfterCommit = true
            if env["FREEV6_DNS_CRASH_STAGE"] == "apply" { try tx.apply() }
            else { _ = try tx.restore() }
            return XCTFail("Expected test host to stop at the committed preferences boundary")
        }
        try fixture { prefs, dir, id in
            try dir.write("test-primary.json", data: JSONEncoder().encode(prefs.primary), mode: 0o600)
            let tx = try SessionDNSTransaction(isolated: dir, sessionID: id, preferences: prefs)
            try tx.prepare()
            let runner = (env["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer") + "/usr/bin/xctest"
            let bundle = Bundle(for: SessionDNSTests.self).bundlePath
            for stage in ["apply", "restore"] {
                let child = try OwnedChildProcess(executable: "/usr/bin/env", arguments: [
                    "FREEV6_DNS_CRASH_FIXTURE=" + id.uuidString, "FREEV6_DNS_CRASH_STAGE=" + stage,
                    runner, "-XCTest", "FreeV6SystemTests.SessionDNSTests/testFreshProcessRecoversAfterSIGKILLAtDNSCommitAndRollbackCommit", bundle
                ], directory: dir.path)
                XCTAssertEqual(try child.runToExit(timeout: 10), .signaled(SIGKILL))
                let record = try PropertyListDecoder().decode(SessionDNSRecord.self,
                    from: XCTUnwrap(dir.read(SessionDNSTransaction.journalName, limit: 262_144)))
                XCTAssertEqual(record.phase, stage == "apply" ? .applying : .restoring)
                XCTAssertEqual(try prefs.dns(prefs.first) != nil, stage == "apply")
            }
            XCTAssertEqual(try tx.restore(), DNSRecoveryResult())
            XCTAssertNil(try prefs.dns(prefs.first))
            XCTAssertEqual(try prefs.dns(prefs.second), [:])
            XCTAssertEqual(prefs.activations, 1)
        }
    }

    func testListenerOwnershipRejectsCompetingSocketsAndIncompleteListings() {
        let own = "p123\nf4\nPTCP\nn127.0.0.1:1053\nTST=LISTEN\nf5\nPUDP\nn127.0.0.1:1053\n"
        XCTAssertTrue(CoreDNSListener.ownsListeners(own, pid: 123, port: 1053))
        for listing in [own.replacingOccurrences(of: "LISTEN", with: "ESTABLISHED"), own.replacingOccurrences(of: "p123", with: "p456"),
                        own + "p456\nf6\nPUDP\nn*:1053\n", own.replacingOccurrences(of: "PUDP", with: "P???")] {
            XCTAssertFalse(CoreDNSListener.ownsListeners(listing, pid: 123, port: 1053))
        }
    }

    func testListenerReadinessRequiresTheSameJobPID() {
        var reads = 0
        XCTAssertThrowsError(try CoreDNSListener.waitUntilReady(port: 1053, sessionID: UUID()) {
            reads += 1
            return reads == 1 ? 123 : 456
        }) { XCTAssertEqual($0 as? SessionDNSError, .resolverUnavailable) }
        XCTAssertEqual(reads, 2)
    }

    func testPinnedCoreAnswersSessionDNSOverTCPAndUDP() throws {
        guard let fixtures = ProcessInfo.processInfo.environment["FREEV6_RUNTIME_FIXTURES_DIR"] else {
            throw XCTSkip("Set FREEV6_RUNTIME_FIXTURES_DIR for the pinned Darwin core")
        }
        try fixture { _, dir, id in
            let asset = try XCTUnwrap(ApprovedResourceCatalog.native.first { $0.architecture != nil })
            let core = URL(fileURLWithPath: fixtures).appendingPathComponent(ApprovedResourceCatalog.nativeArchitecture == "arm64" ? "mihomo-darwin-arm64" : "mihomo-darwin-amd64-v1").path
            let fd = open(core, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw ResourceStoreError.io }
            defer { close(fd) }
            try ResourceIO.scan(fd, limit: asset.limit, expected: asset.sha256, deadline: ResourceIO.deadline())
            let port = try ephemeralPort()
            let business = try JSONDecoder().decode(BusinessConfiguration.self,
                from: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-business-configuration.json")))
            let assembled = try ServiceConfigurationAssembler.assemble(business, sessionID: id)
            let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: assembled.data) as? [String: Any])
            var dns = try XCTUnwrap(policy["dns"] as? [String: Any])
            dns["listen"] = "127.0.0.1:\(port)"
            dns.removeValue(forKey: "nameserver-policy")
            dns["default-nameserver"] = ["127.0.0.1"]
            dns["nameserver"] = ["tcp://127.0.0.1:1"]
            dns["proxy-server-nameserver"] = dns["nameserver"]
            let config: [String: Any] = ["mode": "direct", "log-level": "error", "port": 0, "mixed-port": 0,
                "hosts": try XCTUnwrap(policy["hosts"]), "geo-auto-update": false,
                "tun": ["enable": false], "dns": dns, "rules": ["MATCH,DIRECT"]]
            try dir.write("core.json", data: JSONSerialization.data(withJSONObject: config, options: .withoutEscapingSlashes), mode: 0o600)
            try dir.write("synthetic.log", data: Data(), mode: 0o600)
            let log = try FileHandle(forWritingTo: URL(fileURLWithPath: dir.path + "/synthetic.log"))
            defer { try? log.close() }
            let child = try OwnedChildProcess(executable: core, arguments: ["-d", dir.path, "-f", dir.path + "/core.json"], directory: dir.path, standardOutput: log)
            defer { _ = try? child.stop() }
            try CoreDNSListener.waitUntilReady(port: port, sessionID: id) {
                try child.wait(timeout: 0) == nil ? child.pid : nil
            }
            XCTAssertThrowsError(try CoreDNSListener.verify(pid: getpid(), port: port, sessionID: id))
            XCTAssertThrowsError(try CoreDNSListener.verify(pid: child.pid, port: port, sessionID: UUID()))
            XCTAssertEqual(try child.stop().exit, .exited(0))
        }
    }

    private func ephemeralPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard ok else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
