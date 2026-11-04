import Darwin
import Foundation
import Security
import XCTest
@testable import FreeV6System

private final class FakeController: ServiceControlling {
    var loaded = false
    var failHealth = false
    var failStart = false
    var starts = 0
    func isLoaded() throws -> Bool { loaded }
    func stop() throws { loaded = false }
    func start(plist: String) throws {
        if failStart { throw InstallationError.launchd("test start failure") }
        loaded = true
        starts += 1
    }
    func healthCheck(identity: CodeIdentity) throws {
        if failHealth { throw ServiceClientError.timeout }
    }
}

final class ServiceInstallerTests: XCTestCase {
    private func fixture(_ body: (InstallationLayout, FakeController, ServiceInstaller) throws -> Void) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("build/installer-tests/\(UUID().uuidString)")
        for name in ["helpers", "daemons"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(helpers: root.path + "/helpers", daemons: root.path + "/daemons", data: root.path + "/data")
        let controller = FakeController()
        try body(layout, controller, ServiceInstaller(layout: layout, owner: geteuid(), controller: controller))
    }

    private func payload(_ value: String) throws -> InstallationPayload {
        let identity = try CodeIdentity(identifier: "test", cdHash: String(repeating: value, count: 40))
        let registration = try ServiceRegistration(service: identity, clients: [RegisteredClient(uid: geteuid(), identity: identity)])
        return InstallationPayload(service: Data("service-\(value)".utf8), recovery: Data("recovery-\(value)".utf8), registration: registration)
    }

    func testInstallUpgradeAndIdempotentUninstall() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            XCTAssertTrue(controller.loaded)
            try installer.install(payload("b"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)), Data("service-b".utf8))
            let plist = try Data(contentsOf: URL(fileURLWithPath: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist"))
            let value = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
            XCTAssertEqual(value["ProgramArguments"] as? [String], [layout.helpers + "/" + ServiceProtocolVersion.machService])
            XCTAssertEqual(value["AbandonProcessGroup"] as? Bool, false)
            try installer.uninstall()
            try installer.uninstall()
            XCTAssertFalse(controller.loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.data + "/service-registration.json"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
        }
    }

    func testFailedUpgradeRestoresAllPreviousFilesAndService() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            let old = try Data(contentsOf: URL(fileURLWithPath: layout.data + "/service-registration.json"))
            controller.failHealth = true
            XCTAssertThrowsError(try installer.install(payload("b")))
            XCTAssertTrue(controller.loaded)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.data + "/service-registration.json")), old)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)), Data("service-a".utf8))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/dev.freev6.service-installer")), Data("recovery-a".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
        }
    }

    func testReenrollmentReplacesCurrentUserAndPreservesOtherUsers() throws {
        try fixture { layout, _, installer in
            let first = try payload("a")
            let old = try ServiceRegistration(service: first.registration.service, clients: [
                RegisteredClient(uid: 501, identity: first.registration.service),
                RegisteredClient(uid: 502, identity: first.registration.service),
                RegisteredClient(uid: 0, identity: first.registration.service),
            ])
            try installer.install(InstallationPayload(service: first.service, recovery: first.recovery, registration: old))
            let second = try payload("b")
            let replacement = try ServiceRegistration(service: second.registration.service, clients: [
                RegisteredClient(uid: 501, identity: second.registration.service),
                RegisteredClient(uid: 0, identity: second.registration.service),
            ])
            try installer.install(InstallationPayload(service: second.service, recovery: second.recovery, registration: replacement))
            let bytes = try Data(contentsOf: URL(fileURLWithPath: layout.data + "/service-registration.json"))
            let stored = try ServiceRegistration.decode(bytes)
            XCTAssertEqual(stored.clients.count, 3)
            XCTAssertTrue(stored.requirement(for: 501)!.contains(second.registration.service.cdHash))
            XCTAssertFalse(stored.requirement(for: 501)!.contains(first.registration.service.cdHash))
            XCTAssertTrue(stored.requirement(for: 502)!.contains(first.registration.service.cdHash))
            XCTAssertTrue(stored.requirement(for: 0)!.contains(second.registration.service.cdHash))
        }
    }

    func testFailedFirstInstallLeavesNoServiceFiles() throws {
        try fixture { layout, controller, installer in
            controller.failHealth = true
            XCTAssertThrowsError(try installer.install(payload("a")))
            XCTAssertFalse(controller.loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.helpers + "/" + ServiceProtocolVersion.machService))
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.data + "/service-registration.json"))
        }
    }

    func testInterruptedFirstInstallIsRecoveredByNextProcess() throws {
        try fixture { layout, controller, installer in
            let state = try SecureDirectory(path: layout.state, owner: geteuid())
            let previous = Dictionary(uniqueKeysWithValues: ["service", "recovery", "registration", "plist"].map { ($0, false) })
            let record = InstallationJournal(wasLoaded: false, previous: previous, digests: [:])
            try state.write("transaction.json", data: JSONEncoder().encode(record), mode: 0o600)
            let helpers = try SecureDirectory(path: layout.helpers, owner: geteuid())
            try helpers.write(ServiceProtocolVersion.machService, data: Data("partial".utf8), mode: 0o755)
            controller.loaded = true
            let nextProcess = try ServiceInstaller(layout: layout, owner: geteuid(), controller: controller)
            try nextProcess.recover()
            XCTAssertFalse(controller.loaded)
            XCTAssertNil(try helpers.read(ServiceProtocolVersion.machService, limit: 100))
            XCTAssertNil(try state.read("transaction.json", limit: 4096))
        }
    }

    func testFailedRollbackPreservesJournalAndBackups() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            controller.failStart = true
            XCTAssertThrowsError(try installer.install(payload("b")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: layout.state + "/previous-service"))
            controller.failStart = false
            try installer.recover()
            XCTAssertTrue(controller.loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
        }
    }

    func testNetworkRecoveryRecordPreventsReplacementOrUninstall() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            try Data("pending".utf8).write(to: URL(fileURLWithPath: layout.data + "/network-session.json"))
            XCTAssertThrowsError(try installer.recover())
            XCTAssertThrowsError(try installer.install(payload("b")))
            XCTAssertThrowsError(try installer.uninstall())
            XCTAssertTrue(controller.loaded)
        }
    }

    func testSessionLeasePreventsInstallRecoveryAndUninstallBeforeJournalExists() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            var sessions: PreparedSessionStore? = try PreparedSessionStore(path: layout.data, owner: geteuid())
            XCTAssertNil(try sessions!.current())
            XCTAssertThrowsError(try installer.install(payload("b")))
            XCTAssertThrowsError(try installer.recover())
            XCTAssertThrowsError(try installer.uninstall())
            XCTAssertTrue(controller.loaded)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)), Data("service-a".utf8))
            sessions = nil
            try installer.uninstall()
            XCTAssertFalse(controller.loaded)
        }
    }

    func testCorruptedRollbackBackupIsNotUsedOrDiscarded() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            controller.failStart = true
            XCTAssertThrowsError(try installer.install(payload("b")))
            let state = try SecureDirectory(path: layout.state, owner: geteuid())
            try state.write("previous-service", data: Data("corrupted".utf8), mode: 0o600)
            controller.failStart = false
            XCTAssertThrowsError(try installer.recover())
            XCTAssertFalse(controller.loaded)
            XCTAssertNotNil(try state.read("transaction.json", limit: 4096))
            XCTAssertEqual(try state.read("previous-service", limit: 100), Data("corrupted".utf8))
        }
    }

    func testSymlinkDestinationIsNotOverwritten() throws {
        try fixture { layout, _, installer in
            let target = URL(fileURLWithPath: layout.data + "/unrelated")
            try Data("preserve".utf8).write(to: target)
            let link = URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try installer.install(payload("a")))
            XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
            XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        }
    }

    func testCommittedTransactionCleanupNeverRestoresPartialBackups() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("b"))
            let state = try SecureDirectory(path: layout.state, owner: geteuid())
            let transaction = InstallationJournal(committed: true, wasLoaded: false,
                previous: Dictionary(uniqueKeysWithValues: ["service", "recovery", "registration", "plist"].map { ($0, false) }), digests: [:])
            try state.write("transaction.json", data: JSONEncoder().encode(transaction), mode: 0o600)
            try installer.recover()
            XCTAssertTrue(controller.loaded)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)), Data("service-b".utf8))
            XCTAssertNil(try state.read("transaction.json", limit: 4096))
        }
    }

    func testInstallationLockRejectsConcurrentMutation() throws {
        try fixture { layout, _, installer in
            let state = try SecureDirectory(path: layout.state, owner: geteuid())
            try state.withLock {
                XCTAssertThrowsError(try installer.install(payload("a")))
            }
            try installer.install(payload("a"))
        }
    }

    func testRuntimeProtectionRejectsDebuggingAndLibraryInjection() throws {
        let flags = SecCodeSignatureFlags.runtime.rawValue
        XCTAssertNoThrow(try RuntimeProtection.validate(flags: flags, entitlements: [:]))
        XCTAssertThrowsError(try RuntimeProtection.validate(flags: 0, entitlements: [:]))
        for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-jit", "unexpected.future.right"] {
            XCTAssertThrowsError(try RuntimeProtection.validate(flags: flags, entitlements: [key: true]))
        }
    }
}
