import Foundation
import XCTest
import FreeV6UpdateSupport
@testable import FreeV6System

final class UpdateTransactionTests: XCTestCase {
    func testUpgradeIntentSurvivesRestartAndOnlyMatchingBuildCanClearIt() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("build/upgrade-records/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = Data("runtime fixture".utf8), service = Data("service fixture".utf8)
        let body: [String: Any] = ["format": 1, "build": 2, "minimumSourceBuild": 1, "maximumSourceBuild": 1,
                                  "architecture": UpdateRelease.architecture, "workerProtocol": 1, "serviceProtocol": 6,
                                  "settingsSchema": 1, "runtimeCatalogSHA256": InstallationPayload.digest(catalog),
                                  "serviceSHA256": InstallationPayload.digest(service)]
        let release = try UpdateRelease.decode(JSONSerialization.data(withJSONObject: body), currentBuild: 1)
        let record = try UpdateTransaction(sourceBuild: 1, release: release)
        let resources = root.appendingPathComponent("Resources")
        let services = root.appendingPathComponent("Library/LaunchServices")
        for folder in [resources, services] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(release).write(to: resources.appendingPathComponent("update-compatibility.json"))
        let catalogFile = resources.appendingPathComponent("runtime-assets.json")
        try catalog.write(to: catalogFile)
        let serviceFile = services.appendingPathComponent("dev.freev6.network-service")
        try service.write(to: serviceFile)
        XCTAssertNoThrow(try record.verifyInstalledPayload(contents: root, build: 2))
        XCTAssertThrowsError(try record.verifyInstalledPayload(contents: root, build: 3))
        try service.write(to: catalogFile)
        XCTAssertThrowsError(try record.verifyInstalledPayload(contents: root, build: 2))
        try catalog.write(to: catalogFile)
        try catalog.write(to: serviceFile)
        XCTAssertThrowsError(try record.verifyInstalledPayload(contents: root, build: 2))
        let store = UpdateTransactionStore(root: root)
        XCTAssertNil(try store.load())
        try store.save(record)
        let restarted = UpdateTransactionStore(root: root)
        XCTAssertEqual(try restarted.load()?.release, release)
        try restarted.clear(targetBuild: 3)
        XCTAssertNotNil(try restarted.load())
        try restarted.clear(targetBuild: 2)
        XCTAssertNil(try restarted.load())
        let target = root.appendingPathComponent("outside")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("update-v1/pending.json"), withDestinationURL: target)
        XCTAssertThrowsError(try store.save(record))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }
}
