import XCTest
@testable import FreeV6Business

final class WorkerClientTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [WorkerProgress] = []
        func append(_ update: WorkerProgress) { lock.lock(); values.append(update); lock.unlock() }
        func snapshot() -> [WorkerProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testShutdownDuringDownloadWaitsForChildAndRejectsPendingRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-worker-shutdown-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        // A protocol peer that leaves a download pending until stdin closes.
        // Its exit marker proves shutdown awaited EOF handling, not just a UI flag.
        let script = """
        #!/usr/bin/python3
        import json, pathlib, struct, sys
        def emit(value):
            body = json.dumps(value).encode()
            sys.stdout.buffer.write(struct.pack('>I', len(body)) + body)
            sys.stdout.buffer.flush()
        while True:
            header = sys.stdin.buffer.read(4)
            if not header: break
            request = json.loads(sys.stdin.buffer.read(struct.unpack('>I', header)[0]))
            if request['method'] == 'initialize':
                emit({'jsonrpc':'2.0', 'id':request['id'], 'result': {
                    'protocolVersion':1, 'workerVersion':'fixture', 'platform':'darwin', 'architecture':'\(architecture)',
                    'capabilities':['settings.get','settings.patch','runtime.status','runtime.download'],
                    'maxFrameBytes':1048576, 'maxInFlight':8}})
            elif request['method'] == 'runtime.download':
                emit({'jsonrpc':'2.0','method':'$/progress','params':{
                    'requestId':request['id'],'sequence':1,'phase':'downloading',
                    'received':0,'total':-1,'attempt':1,'attempts':1}})
        pathlib.Path(__file__).with_name('finished').write_text('stdin closed')
        """
        let executable = root.appendingPathComponent("fixture")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = WorkerClient(location: WorkerLocation(executable: executable,
            data: root.appendingPathComponent("data"), resources: resources,
            cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs")))
        let progress = expectation(description: "download started")
        let download = Task { try await client.downloadRuntime { _ in progress.fulfill() } }
        await fulfillment(of: [progress], timeout: 3)
        let start = Date()
        download.cancel()
        await client.shutdown()
        do { _ = try await download.value; XCTFail("pending download succeeded after shutdown") }
        catch { XCTAssertTrue(error is CancellationError || error as? WorkerClientError == .disconnected) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("finished")), "stdin closed")
    }

    func testRealRuntimeArchiveAndProgress() async throws {
        guard let binary = ProcessInfo.processInfo.environment["FREEV6_WORKER_TEST_BINARY"],
              let fixtures = ProcessInfo.processInfo.environment["FREEV6_RUNTIME_FIXTURES_DIR"] else {
            throw XCTSkip("Set worker binary and official runtime fixtures to exercise real runtime verification")
        }
        struct Catalog: Decodable { let assets: [Asset] }
        struct Asset: Decodable { let os: String; let arch: String; let archive: String; let sha256: String }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: repository.appendingPathComponent("internal/mihomo/runtime-assets.json")))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let asset = try XCTUnwrap(catalog.assets.first { $0.os == "darwin" && $0.arch == architecture })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-runtime-test-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("resources")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkerClient(location: WorkerLocation(executable: URL(fileURLWithPath: binary),
            data: root.appendingPathComponent("data"), resources: resources, cache: cache, logs: root.appendingPathComponent("logs")))
        do {
            let empty = try await client.runtimeStatus()
            XCTAssertFalse(empty.available)
            XCTAssertEqual(empty.architecture, architecture)
            let artifact = cache.appendingPathComponent("runtime/\(asset.sha256)/\(asset.archive)")
            try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixtures).appendingPathComponent(asset.archive), to: artifact)
            let recorder = ProgressRecorder()
            let prepared = try await client.downloadRuntime { recorder.append($0) }
            XCTAssertTrue(prepared.available)
            XCTAssertEqual(prepared.sha256, asset.sha256)
            let updates = recorder.snapshot()
            XCTAssertEqual(updates.first?.phase, "checking")
            XCTAssertTrue(updates.allSatisfy { !$0.requestId.isEmpty && $0.sequence > 0 })
            let status = try await client.runtimeStatus()
            XCTAssertEqual(status, prepared)
            let files = try FileManager.default.contentsOfDirectory(atPath: artifact.deletingLastPathComponent().path)
            XCTAssertEqual(files, [asset.archive])
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

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
            XCTAssertTrue(one.capabilities.contains("warp.register"))
            do {
                _ = try await client.registerWarp(name: "invalid\nname") { _ in }
                XCTFail("invalid registration name reached network")
            } catch let error as WorkerRemoteError { XCTAssertEqual(error.code, -32602) }
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
