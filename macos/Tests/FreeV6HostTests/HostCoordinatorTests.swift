import Foundation
import XCTest
import FreeV6Business
@testable import FreeV6Host

@MainActor final class HostCoordinatorTests: XCTestCase {
    func testWorkerProcessAndSharedWindowState() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let binary = env["FREEV6_WORKER_TEST_BINARY"], let child = env["FREEV6_PROCESS_TEST_BINARY"] else {
            throw XCTSkip("set FREEV6_WORKER_TEST_BINARY and FREEV6_PROCESS_TEST_BINARY for the isolated integration")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("build/host-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let resources = dir.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        for name in ["agreement", "privacy"] { try Data(name.utf8).write(to: dir.appendingPathComponent(name + ".md")) }
        let domain = "dev.freev6.host-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let location = WorkerLocation(executable: URL(fileURLWithPath: binary), data: dir.appendingPathComponent("data"), resources: resources,
                                       cache: dir.appendingPathComponent("cache"), logs: dir.appendingPathComponent("logs"))
        let host = FreeV6HostCoordinator(location: location, defaults: defaults,
            backend: IsolatedHostSession(executable: URL(fileURLWithPath: child)), isolated: true, notices: dir)
        var first: [Int] = [], second: [Int] = []
        let window1 = host.observe { if let cursor = $0["cursor"] as? Int { first.append(cursor) } }
        _ = host.observe { if let cursor = $0["cursor"] as? Int { second.append(cursor) } }
        var state = await host.snapshot()
        func request(_ name: String, _ args: [String: Any] = [:], id: String = UUID().uuidString) -> [String: Any] {
            ["version": 1, "id": id, "name": name, "sessionId": state["sessionId"] ?? NSNull(),
             "revision": state["revision"] ?? NSNull(), "sessionRevision": state["sessionRevision"] ?? NSNull(),
             "controlToken": state["controlToken"] ?? NSNull(), "arguments": args]
        }
        func run(_ envelope: [String: Any], ok: Bool = true, line: UInt = #line) async -> [String: Any] {
            let response = await host.command(envelope)
            XCTAssertEqual(response["ok"] as? Bool, ok, response["error"] as? String ?? "", line: line)
            state = response["snapshot"] as? [String: Any] ?? [:]
            return response
        }
        _ = await run(request("preparation.accept"))
        XCTAssertEqual(state["phase"] as? String, "idle")
        XCTAssertEqual((state["capabilities"] as? [String: Bool])?["checkConfiguration"], true)
        _ = await run(request("setup.finish"), ok: false)
        _ = await run(request("setup.start"))
        for _ in 0..<100 where host.setupTask != nil { try await Task.sleep(for: .milliseconds(20)) }
        state = await host.snapshot()
        XCTAssertEqual(host.setupStep, 5)
        XCTAssertNil(host.setupError)
        XCTAssertFalse(host.settings.setupCompleted)
        _ = await run(request("setup.finish"))
        XCTAssertTrue(host.settings.setupCompleted)
        _ = await run(request("checkConfiguration"))
        XCTAssertEqual(state["phase"] as? String, "idle")
        XCTAssertTrue(state["sessionId"] is NSNull)
        XCTAssertTrue((state["configurationCheckMessage"] as? String)?.contains("隔离配置检查通过") == true)
        let checkedService = try await host.backend.status(nil)
        XCTAssertEqual(checkedService.phase.rawValue, "stopped")
        let selectMode = request("setMode", ["mode": "global"])
        _ = await run(selectMode)
        let revision = state["revision"] as? Int64
        _ = await run(selectMode)
        XCTAssertEqual(state["revision"] as? Int64, revision)
        var collision = selectMode; collision["arguments"] = ["mode": "direct"]
        let duplicate = await run(collision, ok: false)
        XCTAssertEqual(duplicate["code"] as? String, "duplicateID")
        // A second window imported settings through the one shared worker.
        let baseline = try await host.worker.settings()
        var changed = baseline.settings; changed.devMode.toggle()
        _ = try await host.worker.save(changed, revision: baseline.revision)
        let outdated = await run(request("setNode", ["node": "北区"]), ok: false)
        XCTAssertEqual(outdated["code"] as? String, "staleRevision")
        XCTAssertTrue(state["preferredNode"] is NSNull)
        let oldSession = request("setNode", ["node": "北区"])
        _ = await run(request("setNode", ["node": "西区"]))
        XCTAssertEqual(state["preferredNode"] as? String, "西区")
        XCTAssertTrue(state["currentNode"] is NSNull)
        _ = await run(request("connect"))
        XCTAssertEqual(state["liveMode"] as? String, "global")
        XCTAssertEqual(state["currentNode"] as? String, "西区")
        XCTAssertEqual((state["capabilities"] as? [String: Bool])?["checkConfiguration"], false)
        let deniedCheck = await run(request("checkConfiguration"), ok: false)
        XCTAssertEqual(deniedCheck["code"] as? String, "busy")
        XCTAssertEqual(state["phase"] as? String, "running")
        _ = await run(request("scenario", ["name": "rejectNextWrite"]))
        let rejected = await run(request("setMode", ["mode": "direct"]), ok: false)
        XCTAssertEqual(rejected["code"] as? String, "unconfirmed")
        XCTAssertEqual(state["savedMode"] as? String, "global")
        XCTAssertEqual(state["liveMode"] as? String, "global")
        let stale = await run(oldSession, ok: false)
        XCTAssertEqual(stale["code"] as? String, "staleSession")
        let oldToken = request("setNode", ["node": "北区"])
        _ = await run(request("setNode", ["node": "东区"]))
        let staleToken = await run(oldToken, ok: false)
        XCTAssertEqual(staleToken["code"] as? String, "staleSession")
        _ = await run(request("measure", ["nodes": ["西区"]]))
        XCTAssertEqual((state["latencies"] as? [String: Any])?["西区"] as? Int, 19)
        XCTAssertEqual(state["currentNode"] as? String, "东区")
        _ = await run(request("download.start", ["group": "access", "node": "西区"]))
        for _ in 0..<100 where host.downloadTask != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.downloadResults["access"]?["西区"]?["bytesPerSecond"] as? Double, 4_000_000)
        for members in [[], ["西区", "西区"], ["不存在的节点"]] {
            _ = await run(request("download.start", ["group": "access", "nodes": members]), ok: false)
        }
        _ = await run(request("download.start", ["group": "access", "nodes": ["西区", "北区", "东区"]]))
        for _ in 0..<100 where host.downloadTask != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.downloadCompleted, 3)
        XCTAssertEqual(host.downloadResults["access"]?.count, 3)
        state = await host.snapshot()
        XCTAssertEqual(state["currentNode"] as? String, "东区")
        _ = await run(request("scenario", ["name": "zeroRate"]))
        try await Task.sleep(for: .milliseconds(2200))
        state = await host.snapshot()
        XCTAssertEqual(state["downloadRate"] as? Double, 0)
        _ = await run(request("scenario", ["name": "recovering"]))
        XCTAssertEqual(state["phase"] as? String, "recovering")
        _ = await run(request("retryRecovery"))
        XCTAssertEqual(state["phase"] as? String, "idle")
        XCTAssertFalse(first.isEmpty); XCTAssertEqual(first, second)
        XCTAssertTrue(zip(first, first.dropFirst()).allSatisfy { $1 > $0 })
        host.removeObserver(window1)
        _ = await run(request("clearLogs"))
        XCTAssertEqual((state["logs"] as? [[String: Any]])?.count, 0)
        _ = await run(request("connect"))
        XCTAssertGreaterThan((state["logs"] as? [[String: Any]])?.count ?? 0, 0)
        try await host.shutdown()
        let reopened = FreeV6HostCoordinator(location: location, defaults: defaults,
            backend: IsolatedHostSession(executable: URL(fileURLWithPath: child)), isolated: true, notices: dir)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["savedMode"] as? String, "global")
        XCTAssertEqual(restored["preferredNode"] as? String, "东区")
        try await reopened.shutdown()

        defaults.set(true, forKey: "autoRunProxy")
        defaults.set(true, forKey: "silentStart")
        let automatic = FreeV6HostCoordinator(location: location, defaults: defaults,
            backend: IsolatedHostSession(executable: URL(fileURLWithPath: child)), isolated: true, notices: dir)
        var launched = await automatic.snapshot()
        for _ in 0..<25 where launched["phase"] as? String != "running" {
            try await Task.sleep(for: .milliseconds(40))
            launched = await automatic.snapshot()
        }
        XCTAssertEqual(launched["shouldStartHidden"] as? Bool, true)
        XCTAssertEqual(launched["phase"] as? String, "running")
        XCTAssertEqual(launched["currentNode"] as? String, "东区")
        try await automatic.shutdown()
    }
}
