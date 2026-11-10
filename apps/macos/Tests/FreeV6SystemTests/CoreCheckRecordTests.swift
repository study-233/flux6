import Darwin
import Foundation
import XCTest
import FreeV6Configuration
@testable import FreeV6System

final class CoreCheckRecordTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func record() throws -> PreparedSessionRecord {
        let configuration = try JSONDecoder().decode(BusinessConfiguration.self,
            from: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-business-configuration.json")))
        let request = ConfigurationCheckRequest(runtimeID: ApprovedResourceCatalog.native.first { $0.architecture != nil }!.id,
            geodataID: String(ApprovedResourceCatalog.native.first { $0.architecture == nil }!.id.split(separator: "/")[0]),
            settingsRevision: 7, credentialRevision: UUID(), configuration: configuration)
        var record = PreparedSessionRecord(request: request, clientUID: geteuid())
        record.schema = 2; record.phase = .checking
        record.configurationSHA256 = String(repeating: "a", count: 64)
        record.check = CoreCheckRecord(origin: ServiceProcessOrigin(bootID: try ServiceProcessOrigin.bootIdentity(),
            groupID: getpgrp(), ownerUID: geteuid()), coreSHA256: String(repeating: "b", count: 64))
        return record
    }

    func testStagesRequireIntentBeforePIDAndExitBeforeRemoval() throws {
        var record = try record()
        for stage in [CoreCheckRecord.Stage.registering, .registered, .starting] {
            record.check!.stage = stage
            XCTAssertEqual(try PreparedSessionRecord.decode(JSONEncoder().encode(record)), record)
            record.check!.pid = 42
            XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONEncoder().encode(record)))
            record.check!.pid = nil
        }
        record.check!.stage = .started
        XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONEncoder().encode(record)))
        record.check!.pid = 42
        XCTAssertEqual(try PreparedSessionRecord.decode(JSONEncoder().encode(record)), record)
        record.check!.stage = .exited
        XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONEncoder().encode(record)))
        record.check!.exitCode = -9
        XCTAssertEqual(try PreparedSessionRecord.decode(JSONEncoder().encode(record)), record)
        record.check!.stage = .removed
        XCTAssertEqual(try PreparedSessionRecord.decode(JSONEncoder().encode(record)), record)
        record.check!.pid = nil; record.check!.exitCode = nil // Aborted before start or rebooted.
        XCTAssertEqual(try PreparedSessionRecord.decode(JSONEncoder().encode(record)), record)
    }

    func testUnknownNestedFieldsAndMalformedLaunchIdentitiesFailClosed() throws {
        let encoded = try JSONEncoder().encode(record())
        let original = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for (key, value) in [("stage", "running" as Any), ("jobLabel", "unrelated.job" as Any),
                             ("coreSHA256", "../../other" as Any), ("pid", 1 as Any), ("exitCode", NSNull() as Any)] {
            var invalid = original, job = original["check"] as! [String: Any]
            job[key] = value; invalid["check"] = job
            XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        for (key, value) in [("groupID", 1 as Any), ("bootID", "unknown" as Any), ("path", "/arbitrary" as Any)] {
            var invalid = original, job = original["check"] as! [String: Any], origin = job["origin"] as! [String: Any]
            origin[key] = value; job["origin"] = origin; invalid["check"] = job
            XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        var v1 = original; v1["schema"] = 1
        XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONSerialization.data(withJSONObject: v1)))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-key"))
    }

    func testLiveOriginAndPreparationOnlyCleanupCannotDeleteCheckRecord() throws {
        let root = repository.appendingPathComponent("build/n-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreparedSessionStore(path: root.path, owner: geteuid())
        let record = try record()
        let directory = try SecureDirectory(path: root.path, owner: geteuid())
        let bytes = try JSONEncoder().encode(record)
        try directory.write(PreparedSessionStore.journalName, data: bytes, mode: 0o600)
        XCTAssertThrowsError(try store.recoverInterruptedSession())
        XCTAssertThrowsError(try store.recoverPreparation())
        XCTAssertThrowsError(try store.discard(sessionID: record.sessionID, clientUID: geteuid()))
        XCTAssertEqual(try directory.read(PreparedSessionStore.journalName, limit: 4096), bytes)
    }
}
