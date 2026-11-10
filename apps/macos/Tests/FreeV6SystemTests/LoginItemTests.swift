import Foundation
import ServiceManagement
import XCTest
@testable import FreeV6System

final class LoginItemTests: XCTestCase {
    func testManagedFileSystemStatusAndSafeRemoval() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = repository.appendingPathComponent("build/login-item-tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let app = home.appendingPathComponent("Applications/Flux6.app")
        let manager = LoginItemManager(home: home, app: app, authorization: { _ in .enabled })
        XCTAssertEqual(try manager.status(), .absent)
        try manager.setEnabled(true)
        try manager.setEnabled(true)
        XCTAssertEqual(try manager.status(), .enabled)
        let denied = LoginItemManager(home: home, app: app, authorization: { _ in .requiresApproval })
        XCTAssertEqual(try denied.status(), .needsApproval)
        let waiting = LoginItemManager(home: home, app: app, authorization: { _ in .notRegistered })
        XCTAssertEqual(try waiting.status(), .nextLogin)
        let preview = LoginItemManager(home: home, app: home.appendingPathComponent("Downloads/Flux6.app"))
        XCTAssertEqual(try preview.status(), .moved)
        XCTAssertThrowsError(try preview.setEnabled(true))
        try manager.setEnabled(false)
        try manager.setEnabled(false)
        let file = home.appendingPathComponent("Library/LaunchAgents/dev.freev6.desktop.login.plist")
        let foreign = try PropertyListSerialization.data(fromPropertyList: ["Label": "foreign"], format: .xml, options: 0)
        try foreign.write(to: file)
        XCTAssertThrowsError(try manager.setEnabled(true))
        XCTAssertThrowsError(try manager.setEnabled(false))
        XCTAssertEqual(try Data(contentsOf: file), foreign)
        let original = home.appendingPathComponent("original")
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertThrowsError(try manager.setEnabled(false))
        XCTAssertThrowsError(try manager.setEnabled(true))
        XCTAssertEqual(try Data(contentsOf: original), foreign)
    }

    func testLegacyRegistrationCanBeMigratedWithoutLaunchingAnApp() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = repository.appendingPathComponent("build/login-item-tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let legacy = LoginItemManager(home: home, app: home.appendingPathComponent("Applications/FreeV6.app"))
        try legacy.setEnabled(true)
        let current = LoginItemManager(home: home, app: home.appendingPathComponent("Applications/Flux6.app"), authorization: { _ in .enabled })
        XCTAssertEqual(try current.status(), .moved)
        try current.setEnabled(true)
        XCTAssertEqual(try current.status(), .enabled)
        let file = home.appendingPathComponent("Library/LaunchAgents/dev.freev6.desktop.login.plist")
        let contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any]
        XCTAssertEqual(contents?["ProgramArguments"] as? [String], [home.path + "/Applications/Flux6.app/Contents/Helpers/freev6-login-launcher"])
        try current.setEnabled(false)
        XCTAssertEqual(try current.status(), .absent)
    }
}
