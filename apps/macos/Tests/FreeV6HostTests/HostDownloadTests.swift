import Foundation
import XCTest
import FreeV6Business
import FreeV6Desktop
@testable import FreeV6System
@testable import FreeV6Host

private actor DownloadBackend: HostSession {
    var requests: [String] = []
    var simultaneous = 0, maximumSimultaneous = 0
    let suspended: Bool
    let failures: Set<String>
    var continuation: CheckedContinuation<Void, Error>?
    init(suspended: Bool = false, failures: Set<String> = []) { self.suspended = suspended; self.failures = failures }
    func release() { continuation?.resume(); continuation = nil }
    func control(_ query: SessionControlRequest) async throws -> SessionControlReply {
        if query.action == .cancelDownload {
            continuation?.resume(throwing: CancellationError()); continuation = nil
            return SessionControlReply(query, cancelled: true)
        }
        guard query.action == .download, let node = query.member else { throw ServiceClientError.invalidReply }
        requests.append(node); simultaneous += 1; maximumSimultaneous = max(maximumSimultaneous, simultaneous)
        defer { simultaneous -= 1 }
        if suspended { try await withCheckedThrowingContinuation { continuation = $0 } }
        if failures.contains(node) { throw ServiceClientError.unavailable }
        return SessionControlReply(query, download: .init(bytes: 2000000, seconds: 1))
    }
    func health() -> DesktopServiceState { .ready }
    func status(_ id: UUID?) throws -> NetworkSessionReply { throw ServiceClientError.unavailable }
    func check(_ settings: SettingsSnapshot, worker: WorkerClient, withService: Bool) async throws -> String { throw ServiceClientError.unavailable }
    func start(_ idleToken: UUID, settings: SettingsSnapshot, worker: WorkerClient, interactive: Bool,
               authorize: @escaping @Sendable () async throws -> Void) async throws -> NetworkSessionReply { throw ServiceClientError.unavailable }
    func stop(_ id: UUID, revision: UInt64) throws -> NetworkSessionReply { throw ServiceClientError.unavailable }
    func prepare(_ action: ServiceInstallationAction) throws { throw ServiceClientError.unavailable }
}

@MainActor final class HostDownloadTests: XCTestCase {
    private func fixture(_ backend: DownloadBackend, body: (FreeV6HostCoordinator, SessionControlTarget) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "dev.freev6.download-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let location = WorkerLocation(executable: root.appendingPathComponent("unused"), data: root.appendingPathComponent("data"),
            resources: root, cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        let host = FreeV6HostCoordinator(location: location, defaults: defaults, backend: backend, isolated: true, notices: nil)
        let target = SessionControlTarget(sessionID: UUID(), revision: 1)
        let reply = try JSONDecoder().decode(NetworkSessionReply.self, from: JSONSerialization.data(withJSONObject: [
            "protocolVersion": ServiceProtocolVersion.current, "requestID": UUID().uuidString, "phase": "running",
            "sessionID": target.sessionID.uuidString, "revision": 1, "settingsRevision": 1, "credentialRevision": UUID().uuidString]))
        await host.network.refresh { _ in reply }
        try await body(host, target)
        await host.logs.finishWrites()
    }

    func testBatchIsSerialAndContinuesAfterOneNodeFails() async throws {
        let backend = DownloadBackend(failures: ["A"])
        try await fixture(backend) { host, target in
            host.startDownloads(target: target, group: .access, members: ["A", "B", "C"])
            await host.downloadTask?.value
            let requests = await backend.requests, maximum = await backend.maximumSimultaneous
            XCTAssertEqual(requests, ["A", "B", "C"]); XCTAssertEqual(maximum, 1)
            XCTAssertEqual(host.downloadCompleted, 3); XCTAssertEqual(host.downloadTotal, 3)
            XCTAssertEqual(host.downloadResults["access"]?["A"]?["status"] as? String, "failed")
            XCTAssertEqual(host.downloadResults["access"]?["B"]?["bytesPerSecond"] as? Double, 2000000)
            XCTAssertEqual(host.downloadResults["access"]?["C"]?["status"] as? String, "complete")
            XCTAssertNil(host.downloadTask)
        }
    }

    func testCancelInterruptsActiveNodeAndNeverStartsQueuedNodes() async throws {
        let backend = DownloadBackend(suspended: true)
        try await fixture(backend) { host, target in
            host.startDownloads(target: target, group: .access, members: ["A", "B", "C"])
            for _ in 0..<100 {
                if await backend.continuation != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await host.cancelDownload()
            let requests = await backend.requests
            XCTAssertEqual(requests, ["A"])
            XCTAssertEqual(host.downloadCompleted, 0)
            XCTAssertEqual(host.downloadResults["access"]?["A"]?["status"] as? String, "cancelled")
            XCTAssertNil(host.downloadResults["access"]?["B"])
            XCTAssertNil(host.downloadTask); XCTAssertFalse(host.downloadCancelling)
        }
    }

    func testSessionLossDropsLateResultAndStopsTheQueue() async throws {
        let backend = DownloadBackend(suspended: true)
        try await fixture(backend) { host, target in
            host.startDownloads(target: target, group: .access, members: ["A", "B"])
            for _ in 0..<100 {
                if await backend.continuation != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            host.network.invalidate()
            await backend.release()
            await host.downloadTask?.value
            let requests = await backend.requests
            XCTAssertEqual(requests, ["A"])
            XCTAssertTrue((host.downloadSnapshot["results"] as? [String: Any])?.isEmpty == true)
            XCTAssertNil(host.downloadResults["access"]?["B"])
        }
    }
}
