import XCTest
import Network
import FreeV6Business
import FreeV6Desktop
@testable import FreeV6Host

private actor TestProfileStorage: VersionedSecretStorage {
    var stored: SecretSnapshot?
    func read() async throws -> SecretSnapshot? { stored }
    func write(_ data: Data, expectedRevision: UUID?) async throws -> SecretSnapshot {
        guard stored?.revision == expectedRevision else { throw CredentialError.conflict }
        let value = SecretSnapshot(revision: UUID(), data: data)
        stored = value; return value
    }
    func delete(expectedRevision: UUID) async throws {
        guard stored?.revision == expectedRevision else { throw CredentialError.conflict }
        stored = nil
    }
}

@MainActor final class HostSettingsTests: XCTestCase {
    private func environment(needsWorker: Bool = false) throws -> (HostSettings, URL, UserDefaults, String) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = repository.appendingPathComponent("dist/macos/Flux6.app/Contents/Helpers/freev6-worker")
        let executable = ProcessInfo.processInfo.environment["FREEV6_WORKER_TEST_BINARY"].map(URL.init(fileURLWithPath:)) ?? bundled
        if needsWorker && !FileManager.default.isExecutableFile(atPath: executable.path) {
            throw XCTSkip("Build the macOS worker or provide FREEV6_WORKER_TEST_BINARY for the integration scenario.")
        }
        let root = repository.appendingPathComponent("build/host-settings-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        for name in ["agreement","privacy"] { try Data(name.utf8).write(to: root.appendingPathComponent(name+".md")) }
        let suite = "dev.freev6.host-settings-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let location = WorkerLocation(executable: executable, data: root.appendingPathComponent("data"),
            resources: resources,
            cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        let settings = HostSettings(worker: WorkerClient(location: location), defaults: defaults,
            logs: DesktopLogs(directory: location.logs), preview: true, noticesDirectory: root,
            profileKeys: (ChainProfileKey(storage: TestProfileStorage()), ChainProfileKey(storage: TestProfileStorage())))
        return (settings,root,defaults,suite)
    }

    func testAppIconDefaultPersistenceAndRejectedValue() async throws {
        let (page, root, defaults, suite) = try environment()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(page.preferencesMap["appIcon"] as? String, "cow")
        try await page.changePreference(["field": "appIcon", "value": "earth"])
        XCTAssertEqual(defaults.string(forKey: "appIcon"), "earth")
        XCTAssertEqual(page.preferencesMap["appIcon"] as? String, "earth")
        do {
            try await page.changePreference(["field": "appIcon", "value": "../unknown"])
            XCTFail("Unknown icon must be rejected")
        } catch {}
        XCTAssertEqual(page.appIcon, "earth")
        defaults.set("unknown", forKey: "appIcon")
        XCTAssertEqual(page.appIcon, "cow")
    }

    func testLegacyLayoutAndDeliberateEmptyLayoutResetToFlClashDefault() async throws {
        let (page, root, defaults, suite) = try environment()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        page.startup.acceptNotices()
        let empty = Data(#"{"version":1,"tiles":[]}"#.utf8)
        defaults.set(empty, forKey: "dashboardLayout")
        let reopened = HostSettings(worker: page.worker, defaults: defaults, logs: page.logs, preview: true, noticesDirectory: root)
        XCTAssertEqual(reopened.snapshot()["layoutCustom"] as? Bool, true)
        XCTAssertEqual((reopened.snapshot()["layout"] as? [[String:String]])?.count, 0)
        _ = try await reopened.handle("layout.edit", arguments: ["op":"begin"])
        _ = try await reopened.handle("layout.edit", arguments: ["op":"reset"])
        _ = try await reopened.handle("draft.saveAll", arguments: ["window":"main"])
        XCTAssertNil(defaults.object(forKey: "dashboardLayout"))
        XCTAssertEqual(reopened.snapshot()["layoutCustom"] as? Bool, false)
        defaults.set(try DashboardLayout().encoded(), forKey: "dashboardLayout")
        let matching = HostSettings(worker: page.worker, defaults: defaults, logs: page.logs, preview: true, noticesDirectory: root)
        _ = try await matching.handle("layout.edit", arguments: ["op":"begin"])
        _ = try await matching.handle("layout.edit", arguments: ["op":"save"])
        XCTAssertNotNil(defaults.object(forKey: "dashboardLayout"))
        _ = try await matching.handle("layout.edit", arguments: ["op":"begin"])
        _ = try await matching.handle("layout.edit", arguments: ["op":"reset"])
        XCTAssertEqual((matching.snapshot()["drafts"] as? [String:Bool])?["main"], true)
        _ = try await matching.handle("layout.edit", arguments: ["op":"save"])
        XCTAssertNil(defaults.object(forKey: "dashboardLayout"))
        await page.logs.finishWrites()
    }

    func testOldWorkerSettingsSeparateWindowsValidationAndConflict() async throws {
        let (page, root, defaults, suite) = try environment(needsWorker: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: repository.appendingPathComponent("shared/fixtures/worker-settings.json"),
                                         to: folder.appendingPathComponent("proxy-preferences.json"))
        _ = try await page.handle("preparation.accept", arguments: [:])
        XCTAssertEqual(page.stored?.revision, 7)
        func edit(_ window: String, _ field: String, _ value: Any) async throws {
            _ = try await page.handle("rules.edit", arguments:["window":window,"field":field,"value":value])
        }
        try await edit("main","blacklist","example.org\n\nhttps://bad.example")
        try await edit("settings","devMode",false)
        _ = try await page.handle("draft.saveAll",arguments:["window":"settings"])
        XCTAssertEqual(page.stored?.settings.devMode,false)
        do { _ = try await page.handle("draft.saveAll", arguments:["window":"main"]); XCTFail("Invalid domain was saved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("第 3 行"),error.localizedDescription) }
        let main = try XCTUnwrap((page.snapshot()["rules"] as? [String:[String:Any]])?["main"])
        XCTAssertEqual((main["issue"] as? [String:Any])?["line"] as? Int,3)
        XCTAssertEqual(main["blacklist"] as? String,"example.org\n\nhttps://bad.example")
        try await edit("main","blacklist","example.org")
        _ = try await page.handle("draft.saveAll",arguments:["window":"main"])
        XCTAssertEqual(page.stored?.settings.blacklist,["example.org"])
        XCTAssertEqual(page.stored?.settings.devMode,false)
        try await edit("main","blacklist","main.example")
        try await edit("settings","blacklist","second.example")
        _ = try await page.handle("rules.save",arguments:["window":"main"])
        do { _ = try await page.handle("rules.save",arguments:["window":"settings"]); XCTFail("Overwrote another window") }
        catch { XCTAssertTrue(error.localizedDescription.contains("另一窗口")) }
        XCTAssertEqual(page.stored?.settings.blacklist,["main.example"])
        await page.worker.shutdown()
        await page.logs.finishWrites()
    }

    func testFailedSubscriptionCanRetryAgainstRealLoopbackSource() async throws {
        let (page, root, defaults, suite) = try environment(needsWorker: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try await page.handle("preparation.accept", arguments: [:])
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yaml = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/chain-proxies.yaml"))
        let ready = expectation(description: "Loopback fixture server ready")
        let tcp = NWParameters.tcp
        tcp.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: tcp)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "dev.freev6.test.profile-http")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { bytes, _, _, _ in
                let found = bytes.map { String(decoding: $0, as: UTF8.self).hasPrefix("GET /valid?") } ?? false
                let body = found ? yaml : Data()
                var response = Data("HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        await fulfillment(of:[ready],timeout:3)
        let port = try XCTUnwrap(listener.port).rawValue
        func load(_ path: String) async throws {
            _ = try await page.handle("profile.import", arguments:["type":"chain","source":"url","value":"http://127.0.0.1:\(port)/\(path)?token=SyntheticSecret"])
        }
        do { try await load("missing"); XCTFail("Imported an HTTP 404") }
        catch { XCTAssertFalse(error.localizedDescription.contains("SyntheticSecret")) }
        XCTAssertNil(page.stored?.chain)
        try await load("valid")
        XCTAssertEqual(page.stored?.chain?.source,.url)
        XCTAssertEqual(page.stored?.chain?.names,["Socks","HTTP","Shadowsocks","Trojan","VLESS","VMess"])
        let record = try String(contentsOf: root.appendingPathComponent("data/proxy-preferences.json"), encoding:.utf8)
        XCTAssertFalse(record.contains("SyntheticSecret"))
        XCTAssertFalse(record.contains("synthetic-only"))
        await page.worker.shutdown()
        await page.logs.finishWrites()
    }

    func testLogPauseClearNewEventsAndReadReceiptScope() async throws {
        let (page, root, defaults, suite) = try environment(needsWorker: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        page.startup.acceptNotices()
        page.logs.record(.opened); page.logs.record(.settingsFailure)
        _ = try await page.handle("logs.filter",arguments:["level":"错误"])
        _ = try await page.handle("logs.pause",arguments:["paused":true])
        page.logs.record(.controlFailure)
        XCTAssertEqual(page.logs.visible.map(\.event),[.settingsFailure])
        _ = try await page.handle("logs.clear",arguments:[:])
        page.logs.record(.profileFailure)
        XCTAssertTrue(page.logs.visible.isEmpty)
        _ = try await page.handle("logs.pause",arguments:["paused":false])
        XCTAssertEqual(page.logs.visible.map(\.event),[.profileFailure])
        try await page.refreshNotice(online: false)
        _ = try await page.handle("notices.read",arguments:["id":"isolated-profile"])
        let ids = try JSONDecoder().decode([String].self, from: XCTUnwrap(defaults.data(forKey:"maintainerNoticeReadIDs")))
        XCTAssertEqual(ids,["isolated-profile"])
        XCTAssertEqual((page.snapshot()["notices"] as? [String:Any])?["unread"] as? Int,1)
        await page.worker.shutdown()
        await page.logs.finishWrites()
    }
}
