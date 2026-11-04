import XCTest
@testable import FreeV6Business

final class WorkerClientTests: XCTestCase {
    func testFramesAcrossEveryBoundaryAndTruncation() throws {
        let first = Data(#"{"id":"first"}"#.utf8)
        let second = Data(#"{"id":"second"}"#.utf8)
        let wire = try WorkerFrameDecoder.encode(first) + WorkerFrameDecoder.encode(second)
        for split in 0...wire.count {
            var decoder = WorkerFrameDecoder()
            let decoded = try decoder.append(Data(wire.prefix(split))) + decoder.append(Data(wire.dropFirst(split)))
            XCTAssertEqual(decoded, [first, second])
            XCTAssertNoThrow(try decoder.finish())
        }
        var decoder = WorkerFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([255, 255, 255, 255])))
        decoder = WorkerFrameDecoder()
        _ = try decoder.append(Data([0, 0, 0, 4, 123]))
        XCTAssertThrowsError(try decoder.finish())
    }

    func testSharedGoSwiftSettingsFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/worker-settings.json"))
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.settings.mode, .global)
        XCTAssertEqual(snapshot.settings.campusCidrs, ["edu.cn", "202.204.0.0/12", "2001:db8::/32"])
        XCTAssertEqual(snapshot.settings.blacklist, ["ads.example.com"])
        XCTAssertTrue(snapshot.settings.devMode)
    }

    func testRealGoWorkerPersistenceConflictAndRestart() async throws {
        guard let binary = ProcessInfo.processInfo.environment["FREEV6_WORKER_TEST_BINARY"] else {
            throw XCTSkip("Set FREEV6_WORKER_TEST_BINARY to execute the real Swift/Go integration test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-worker-test-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkerClient(location: WorkerLocation(executable: URL(fileURLWithPath: binary),
            data: root.appendingPathComponent("data"), resources: resources,
            cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs")))
        do {
            async let first = client.connect()
            async let second = client.connect()
            let (one, two) = try await (first, second)
            XCTAssertEqual(one.protocolVersion, two.protocolVersion)
            XCTAssertEqual(one.platform, "darwin")
            let defaults = try await client.settings()
            XCTAssertEqual(defaults.revision, 0)
            XCTAssertEqual(defaults.settings.mode, .rule)
            var preferences = defaults.settings
            preferences.mode = .global
            preferences.campusCidrs = [" EDU.CN ", "2001:db8::/32"]
            preferences.devMode = true
            let saved = try await client.save(preferences, revision: defaults.revision)
            XCTAssertEqual(saved.revision, 1)
            XCTAssertEqual(saved.settings.campusCidrs, ["edu.cn", "2001:db8::/32"])
            do {
                _ = try await client.save(defaults.settings, revision: defaults.revision)
                XCTFail("stale save succeeded")
            } catch let error as WorkerRemoteError { XCTAssertEqual(error.code, -32004) }
            var invalid = saved.settings
            invalid.blacklist = ["https://example.com"]
            do { _ = try await client.save(invalid, revision: saved.revision); XCTFail("invalid policy saved") }
            catch let error as WorkerRemoteError { XCTAssertEqual(error.code, -32602) }
            await client.shutdown()
            let restarted = try await client.settings()
            XCTAssertEqual(restarted, saved)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("data").path)
        XCTAssertEqual(Set(files), Set(["proxy-preferences.json", "worker.lock"]))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("data/proxy-preferences.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWorkerExitAndUnresponsiveWorkerDoNotHangClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-worker-fault-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, script) in ["#!/bin/sh\nexit 0\n", "#!/bin/sh\nexec /bin/sleep 30\n"].enumerated() {
            let executable = root.appendingPathComponent("fixture-\(index)")
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = WorkerClient(location: WorkerLocation(executable: executable,
                data: root.appendingPathComponent("data"), resources: resources,
                cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs")))
            let start = Date()
            do { try await client.connect(); XCTFail("non-worker process completed handshake") }
            catch {
                if index == 1 { XCTAssertEqual(error as? WorkerClientError, .timeout) }
            }
            await client.shutdown()
            XCTAssertLessThan(Date().timeIntervalSince(start), 15)
        }
    }
}
