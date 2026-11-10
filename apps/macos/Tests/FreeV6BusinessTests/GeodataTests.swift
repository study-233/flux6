import Foundation
import XCTest
@testable import FreeV6Business

final class GeodataTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testGeodataRejectsInconsistentReadinessAndUnsafeMetadata() throws {
        let digest = String(repeating: "a", count: 64)
        let revision = String(repeating: "b", count: 40)
        let files: [[String: Any]] = ["GeoSite.dat", "geoip.dat", "country.mmdb"].map {
            ["name": $0, "size": 128, "sha256": digest, "available": true]
        }
        let valid: [String: Any] = ["resourceId": "geodata-\(revision)", "revision": revision, "available": true, "files": files]
        func decode(_ object: [String: Any]) throws -> GeodataPackageInfo {
            try JSONDecoder().decode(GeodataPackageInfo.self, from: JSONSerialization.data(withJSONObject: object)).validated()
        }
        XCTAssertTrue(try decode(valid).available)
        var invalid = valid; invalid["available"] = false
        XCTAssertThrowsError(try decode(invalid))
        invalid = valid; invalid["revision"] = "../escape"
        XCTAssertThrowsError(try decode(invalid))
        var badFiles = files; badFiles[0]["name"] = "../../file"
        invalid = valid; invalid["files"] = badFiles
        XCTAssertThrowsError(try decode(invalid))
        badFiles = files; badFiles[0]["sha256"] = String(repeating: "z", count: 64)
        invalid["files"] = badFiles
        XCTAssertThrowsError(try decode(invalid))
        badFiles = files; badFiles[0]["size"] = 33 * 1024 * 1024
        invalid["files"] = badFiles
        XCTAssertThrowsError(try decode(invalid))
    }

    func testRealWorkerCopiesVerifiedSeedsAndRepairsCache() async throws {
        guard let binary = ProcessInfo.processInfo.environment["FREEV6_WORKER_TEST_BINARY"],
              let fixtures = ProcessInfo.processInfo.environment["FREEV6_GEODATA_FIXTURES_DIR"] else {
            throw XCTSkip("Set worker binary and official geodata fixtures for the real Swift/Go integration")
        }
        struct Catalog: Decodable {
            struct Asset: Decodable { let name: String; let size: Int64; let sha256: String }
            let revision: String
            let assets: [Asset]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: repository.appendingPathComponent("internal/mihomo/geodata-assets.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-geodata-test-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("resources")
        let seeds = resources.appendingPathComponent("Geodata/\(catalog.revision)")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for asset in catalog.assets {
            let seed = seeds.appendingPathComponent(asset.name)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixtures).appendingPathComponent(asset.name), to: seed)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: seed.path)
        }
        let client = WorkerClient(location: WorkerLocation(executable: URL(fileURLWithPath: binary), data: root.appendingPathComponent("data"),
            resources: resources, cache: cache, logs: root.appendingPathComponent("logs")))
        do {
            let empty = try await client.geodataStatus()
            XCTAssertFalse(empty.available)
            XCTAssertEqual(empty.revision, catalog.revision)
            let progress = GeodataProgressRecorder()
            let prepared = try await client.prepareGeodata { progress.append($0) }
            XCTAssertTrue(prepared.available)
            XCTAssertTrue(progress.snapshot().contains { $0.phase == "copying" && $0.asset == "GeoSite.dat" })
            XCTAssertFalse(progress.snapshot().contains { $0.phase == "downloading" })
            for asset in catalog.assets {
                let file = try XCTUnwrap(prepared.files.first { $0.name == asset.name })
                XCTAssertEqual(file.size, asset.size)
                XCTAssertEqual(file.sha256, asset.sha256)
                let seed = seeds.appendingPathComponent(asset.name)
                let original = try Data(contentsOf: URL(fileURLWithPath: fixtures).appendingPathComponent(asset.name))
                XCTAssertEqual(try Data(contentsOf: seed), original)
            }
            let destination = cache.appendingPathComponent("geodata/\(catalog.revision)/GeoSite.dat")
            try Data("corrupt".utf8).write(to: destination)
            let corrupt = try await client.geodataStatus()
            XCTAssertFalse(corrupt.available)
            let repaired = try await client.prepareGeodata { _ in }
            XCTAssertEqual(repaired, prepared)
            await client.shutdown()
            let restarted = try await client.geodataStatus()
            XCTAssertEqual(restarted, prepared)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }
}

private final class GeodataProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WorkerProgress] = []
    func append(_ progress: WorkerProgress) { lock.lock(); values.append(progress); lock.unlock() }
    func snapshot() -> [WorkerProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
