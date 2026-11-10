import XCTest
@testable import FreeV6Desktop

@MainActor final class DesktopStartupTests: XCTestCase {
    func testInstallationLocationUsesVolumeAndSystemRelocation() throws {
        let installed = URL(fileURLWithPath: "/Applications/Flux6.app")
        XCTAssertTrue(ApplicationLocation.requiresInstallation(path: installed, readOnly: true))
        XCTAssertFalse(ApplicationLocation.requiresInstallation(path: installed, readOnly: false))
        let relocated = URL(fileURLWithPath: "/private/var/folders/example/AppTranslocation/4046889A-9DF0-4CE1-BB36-61BD96A22835/d/Flux6.app")
        XCTAssertTrue(ApplicationLocation.requiresInstallation(path: relocated, readOnly: false))
        let project = URL(fileURLWithPath: "/Users/example/AppTranslocation/project/Flux6.app")
        XCTAssertFalse(ApplicationLocation.requiresInstallation(path: project, readOnly: false))
        XCTAssertFalse(try ApplicationLocation.requiresInstallation(at: FileManager.default.temporaryDirectory))
    }

    func testConsentVisibilityAndOneAttemptPerLaunch() throws {
        let suite = "dev.freev6.test.startup." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("Test terms".utf8).write(to: folder.appendingPathComponent("agreement.md"))
        let privacy = folder.appendingPathComponent("privacy.md")
        try Data("Test privacy".utf8).write(to: privacy)
        let documents = try StartupNotices(directory: folder)
        defaults.set(true, forKey: "autoRunProxy")
        defaults.set(true, forKey: "silentStart")
        let first = DesktopStartup(defaults: defaults, notices: documents)
        XCTAssertFalse(first.accepted)
        XCTAssertFalse(first.shouldStartHidden)
        first.acceptNotices()
        XCTAssertNil(first.takeAutomaticAttempt())

        let launch = DesktopStartup(defaults: defaults, notices: documents)
        XCTAssertTrue(launch.accepted)
        XCTAssertTrue(launch.shouldStartHidden)
        XCTAssertFalse(launch.loginRequested)
        defaults.set(false, forKey: "showMenuBarExtra")
        XCTAssertFalse(launch.shouldStartHidden)
        let token = try XCTUnwrap(launch.takeAutomaticAttempt())
        XCTAssertNil(launch.takeAutomaticAttempt())
        XCTAssertEqual(launch.currentAttempt, token)
        launch.automatic = false
        launch.automatic = true
        XCTAssertNil(launch.currentAttempt)
        XCTAssertNil(launch.takeAutomaticAttempt())
        let manual = DesktopStartup(defaults: defaults, notices: documents)
        manual.cancelAutomatic()
        XCTAssertNil(manual.takeAutomaticAttempt())

        try Data("Changed privacy".utf8).write(to: privacy)
        let changed = DesktopStartup(defaults: defaults, notices: try StartupNotices(directory: folder))
        XCTAssertFalse(changed.accepted)
        XCTAssertNil(changed.takeAutomaticAttempt())
        let missing = DesktopStartup(defaults: defaults, notices: nil)
        missing.acceptNotices()
        XCTAssertFalse(missing.accepted)
    }

    func testFirstLaunchPreventsNewWorkAndAllowsRecovery() {
        var commands = DesktopCommandState()
        commands.noticesAccepted = false
        commands.service = .ready; commands.network = .idle
        commands.configurationReady = true; commands.coreAvailable = true
        for action: DesktopCommand in [.connect, .configureService, .downloadCore, .checkUpdates, .importChain] {
            XCTAssertFalse(commands.availability(action).enabled)
        }
        XCTAssertTrue(commands.availability(.showMain).enabled)
        XCTAssertTrue(commands.availability(.quit).enabled)
        commands.network = .running
        commands.canTargetSession = true
        XCTAssertTrue(commands.availability(.disconnect).enabled)
    }

    func testAutomaticConnectionRechecksAfterEachWaitAndNeverRetries() async throws {
        let suite = "dev.freev6.test.startup." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["agreement.md", "privacy.md"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let docs = try StartupNotices(directory: root)
        let setup = DesktopStartup(defaults: defaults, notices: docs)
        setup.acceptNotices()
        setup.automatic = true
        enum Scenario: CaseIterable { case ready, missingService, offline, occupied, manual, lockedKey, update }
        for scenario in Scenario.allCases {
            let launch = DesktopStartup(defaults: defaults, notices: docs)
            var reason: String? = scenario == .missingService ? "missing" : nil
            var inspected = false
            var starts = 0
            await launch.runAutomatic(prerequisite: { reason }, waitForNetwork: {
                if scenario == .manual { launch.cancelAutomatic() }
                if scenario == .occupied { reason = "occupied" }
                return scenario != .offline
            }, inspect: {
                inspected = true
                if scenario == .lockedKey { throw CocoaError(.fileReadNoPermission) }
                if scenario == .update { reason = "update" }
            }, connect: { token in
                XCTAssertEqual(token, launch.currentAttempt)
                starts += 1
                return nil
            })
            XCTAssertEqual(starts, scenario == .ready ? 1 : 0)
            XCTAssertEqual(inspected, [.ready, .lockedKey, .update].contains(scenario))
            XCTAssertNil(launch.currentAttempt)
            XCTAssertNil(launch.takeAutomaticAttempt())
        }
    }
}
