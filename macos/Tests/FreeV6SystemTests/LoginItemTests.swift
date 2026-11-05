import Foundation
import ServiceManagement
import XCTest
@testable import FreeV6System

final class LoginItemTests: XCTestCase {
    func testManagedFileSystemStatusAndSafeRemoval() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let home = repository.appendingPathComponent("build/login-item-tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let app = home.appendingPathComponent("Applications/FreeV6.app")
        let manager = LoginItemManager(home: home, app: app, authorization: { _ in .enabled })
        XCTAssertEqual(try manager.status(), .absent)
        try manager.setEnabled(true)
        try manager.setEnabled(true)
        XCTAssertEqual(try manager.status(), .enabled)
        let denied = LoginItemManager(home: home, app: app, authorization: { _ in .requiresApproval })
        XCTAssertEqual(try denied.status(), .needsApproval)
        let waiting = LoginItemManager(home: home, app: app, authorization: { _ in .notRegistered })
        XCTAssertEqual(try waiting.status(), .nextLogin)
        let preview = LoginItemManager(home: home, app: home.appendingPathComponent("Downloads/FreeV6.app"))
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
}
