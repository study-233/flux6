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
    var stops = 0
    func isLoaded() throws -> Bool { loaded }
    func stop() throws { loaded = false; stops += 1 }
    func start(plist: String) throws {
        if failStart || !FileManager.default.fileExists(atPath: plist) {
            throw InstallationError.launchd("test start failure")
        }
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
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("build/installer-tests/\(UUID().uuidString)")
        for name in ["helpers", "daemons"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(helpers: root.path + "/helpers", daemons: root.path + "/daemons", data: root.path + "/data")
        let controller = FakeController()
        let installer = try ServiceInstaller(layout: layout, owner: geteuid(), controller: controller,
            installedIdentity: { url, identifier in
                let contents = try String(contentsOf: url, encoding: .utf8)
                let prefix = identifier == ServiceProtocolVersion.machService ? "service-" : "recovery-"
                guard contents == prefix + "a" || contents == prefix + "b", let value = contents.last else {
                    throw IdentityError.invalidIdentity
                }
                return try CodeIdentity(identifier: identifier, cdHash: String(repeating: String(value), count: 40))
            })
        try body(layout, controller, installer)
    }

    private func payload(_ value: String) throws -> InstallationPayload {
        let identity = try CodeIdentity(identifier: ServiceProtocolVersion.machService, cdHash: String(repeating: value, count: 40))
        let recovery = try CodeIdentity(identifier: "dev.freev6.service-installer", cdHash: identity.cdHash)
        let registration = try ServiceRegistration(service: identity, clients: [
            RegisteredClient(uid: geteuid(), identity: identity), RegisteredClient(uid: 0, identity: recovery),
        ])
        return InstallationPayload(service: Data("service-\(value)".utf8), recovery: Data("recovery-\(value)".utf8), registration: registration)
    }

    private func removeLaunchDaemon(_ layout: InstallationLayout) throws -> Data {
        let directory = try SecureDirectory(path: layout.daemons, owner: geteuid())
        let name = ServiceProtocolVersion.machService + ".plist"
        let bytes = try XCTUnwrap(directory.read(name, limit: 4096))
        try directory.remove(name)
        return bytes
    }

    func testRecoveryRebuildsMissingLaunchDaemonWithoutRestartingService() throws {
        for loaded in [false, true] {
            try fixture { layout, controller, installer in
                try installer.install(payload("a"))
                let expected = try removeLaunchDaemon(layout)
                controller.loaded = loaded
                let starts = controller.starts, stops = controller.stops
                try installer.recover()
                let directory = try SecureDirectory(path: layout.daemons, owner: geteuid())
                XCTAssertEqual(try directory.read(ServiceProtocolVersion.machService + ".plist", limit: 4096), expected)
                XCTAssertEqual(controller.loaded, loaded)
                XCTAssertEqual(controller.starts, starts)
                XCTAssertEqual(controller.stops, stops)
                try installer.recover()
                XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
            }
        }
    }

    func testMissingLaunchDaemonCanBeRepairedDuringUpgradeAndUninstall() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            _ = try removeLaunchDaemon(layout)
            try installer.install(payload("b"))
            XCTAssertTrue(controller.loaded)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)), Data("service-b".utf8))
            _ = try removeLaunchDaemon(layout)
            try installer.uninstall()
            XCTAssertFalse(controller.loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.helpers + "/" + ServiceProtocolVersion.machService))
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.data + "/service-registration.json"))
        }
    }

    func testFailedUpgradeAfterLaunchDaemonRepairRestoresStartableService() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            let expected = try removeLaunchDaemon(layout)
            controller.failHealth = true
            XCTAssertThrowsError(try installer.install(payload("b"))) { error in
                guard case ServiceClientError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(controller.loaded)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layout.helpers + "/" + ServiceProtocolVersion.machService)), Data("service-a".utf8))
            let directory = try SecureDirectory(path: layout.daemons, owner: geteuid())
            XCTAssertEqual(try directory.read(ServiceProtocolVersion.machService + ".plist", limit: 4096), expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
        }
    }

    func testMissingLaunchDaemonRepairRejectsUntrustedCodeAndRegistration() throws {
        for fault in ["service-code", "recovery-code", "service-identity", "recovery-identity", "missing-root-client"] {
            try fixture { layout, controller, installer in
                let original = try payload("a")
                try installer.install(original)
                _ = try removeLaunchDaemon(layout)
                let helpers = try SecureDirectory(path: layout.helpers, owner: geteuid())
                let data = try SecureDirectory(path: layout.data, owner: geteuid())
                if fault == "service-code" {
                    try helpers.write(ServiceProtocolVersion.machService, data: Data("invalid".utf8), mode: 0o755)
                } else if fault == "recovery-code" {
                    try helpers.write("dev.freev6.service-installer", data: Data("invalid".utf8), mode: 0o755)
                } else {
                    var clients = original.registration.clients
                    if fault == "recovery-identity" {
                        clients = clients.map { client in
                            client.uid == 0 ? RegisteredClient(uid: 0, identity: original.registration.service) : client
                        }
                    } else if fault == "missing-root-client" {
                        clients.removeAll { $0.uid == 0 }
                    }
                    let service = fault == "service-identity" ? try payload("b").registration.service : original.registration.service
                    let registration = try ServiceRegistration(service: service, clients: clients)
                    try data.write("service-registration.json", data: JSONEncoder().encode(registration), mode: 0o644)
                }
                let starts = controller.starts, stops = controller.stops
                XCTAssertThrowsError(try installer.recover(), fault)
                XCTAssertThrowsError(try installer.install(payload("b")), fault)
                XCTAssertTrue(controller.loaded)
                XCTAssertEqual(controller.starts, starts)
                XCTAssertEqual(controller.stops, stops)
                XCTAssertFalse(FileManager.default.fileExists(atPath: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state + "/transaction.json"))
            }
        }
    }

    func testMissingLaunchDaemonRepairPreservesOtherIncompleteInstallations() throws {
        for missing in ["service", "recovery", "registration"] {
            try fixture { layout, controller, installer in
                try installer.install(payload("a"))
                _ = try removeLaunchDaemon(layout)
                let helpers = try SecureDirectory(path: layout.helpers, owner: geteuid())
                let data = try SecureDirectory(path: layout.data, owner: geteuid())
                switch missing {
                case "service": try helpers.remove(ServiceProtocolVersion.machService)
                case "recovery": try helpers.remove("dev.freev6.service-installer")
                default: try data.remove("service-registration.json")
                }
                let stops = controller.stops
                try installer.recover()
                XCTAssertThrowsError(try installer.install(payload("b"))) { error in
                    guard case InstallationError.inconsistentInstallation = error else { return XCTFail("Unexpected error: \(error)") }
                }
                XCTAssertTrue(controller.loaded)
                XCTAssertEqual(controller.stops, stops)
                XCTAssertFalse(FileManager.default.fileExists(atPath: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist"))
            }
        }
    }

    func testLaunchDaemonRepairPreservesExistingFilesAndRejectsSymlinks() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            let directory = try SecureDirectory(path: layout.daemons, owner: geteuid())
            let name = ServiceProtocolVersion.machService + ".plist"
            let existing = Data("preserve existing configuration".utf8)
            try directory.write(name, data: existing, mode: 0o644)
            let stops = controller.stops
            try installer.recover()
            XCTAssertEqual(try directory.read(name, limit: 4096), existing)
            try directory.remove(name)
            let target = URL(fileURLWithPath: layout.daemons + "/unrelated")
            try existing.write(to: target)
            try FileManager.default.createSymbolicLink(atPath: layout.daemons + "/" + name, withDestinationPath: target.path)
            XCTAssertThrowsError(try installer.recover())
            XCTAssertEqual(try Data(contentsOf: target), existing)
            XCTAssertEqual(controller.stops, stops)
        }
    }

    func testLaunchDaemonRepairWaitsForInstallationAndNetworkRecovery() throws {
        for blocker in ["install-lock", "network-lock", "network-session", "transaction"] {
            try fixture { layout, controller, installer in
                try installer.install(payload("a"))
                _ = try removeLaunchDaemon(layout)
                let state = try SecureDirectory(path: layout.state, owner: geteuid())
                let data = try SecureDirectory(path: layout.data, owner: geteuid())
                var lease: FileHandle?
                defer { try? lease?.close() }
                switch blocker {
                case "install-lock": lease = try state.acquireLock("install.lock")
                case "network-lock": lease = try data.acquireLock("network.lock")
                case "network-session": try data.write("network-session.json", data: Data("pending".utf8), mode: 0o600)
                default: try state.write("transaction.json", data: Data("invalid transaction".utf8), mode: 0o600)
                }
                let stops = controller.stops
                XCTAssertThrowsError(try installer.recover(), blocker)
                XCTAssertThrowsError(try installer.install(payload("b")), blocker)
                XCTAssertThrowsError(try installer.uninstall(), blocker)
                XCTAssertTrue(controller.loaded)
                XCTAssertEqual(controller.stops, stops)
                XCTAssertFalse(FileManager.default.fileExists(atPath: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist"))
            }
        }
    }

    func testRejectedPayloadDoesNotRepairMissingLaunchDaemon() throws {
        try fixture { layout, controller, installer in
            try installer.install(payload("a"))
            _ = try removeLaunchDaemon(layout)
            let stops = controller.stops
            XCTAssertThrowsError(try installer.installPreparing { throw InstallationError.invalidPayload })
            XCTAssertEqual(controller.stops, stops)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.daemons + "/" + ServiceProtocolVersion.machService + ".plist"))
        }
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
            let firstRecovery = try CodeIdentity(identifier: "dev.freev6.service-installer", cdHash: first.registration.service.cdHash)
            let old = try ServiceRegistration(service: first.registration.service, clients: [
                RegisteredClient(uid: 501, identity: first.registration.service),
                RegisteredClient(uid: 502, identity: first.registration.service),
                RegisteredClient(uid: 0, identity: firstRecovery),
            ])
            try installer.install(InstallationPayload(service: first.service, recovery: first.recovery, registration: old))
            _ = try removeLaunchDaemon(layout)
            let second = try payload("b")
            let secondRecovery = try CodeIdentity(identifier: "dev.freev6.service-installer", cdHash: second.registration.service.cdHash)
            let replacement = try ServiceRegistration(service: second.registration.service, clients: [
                RegisteredClient(uid: 501, identity: second.registration.service),
                RegisteredClient(uid: 0, identity: secondRecovery),
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
