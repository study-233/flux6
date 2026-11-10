import Foundation
import XCTest
import FreeV6Business
import FreeV6Desktop
import FreeV6System
@testable import FreeV6Host

private actor ShutdownBackend: HostSession {
    var broken = true
    var healthReads = 0, statusReads = 0, stops = 0
    let idle: NetworkSessionReply
    var current: NetworkSessionReply

    init() throws {
        idle = try JSONDecoder().decode(NetworkSessionReply.self, from: JSONSerialization.data(withJSONObject: [
            "protocolVersion": ServiceProtocolVersion.current, "requestID": UUID().uuidString,
            "phase": "stopped", "idleToken": UUID().uuidString]))
        current = idle
    }
    func repair() { broken = false; current = idle }
    func setCurrent(_ reply: NetworkSessionReply) { broken = false; current = reply }
    func health() throws -> DesktopServiceState {
        healthReads += 1
        if broken { throw InstallationError.inconsistentInstallation }
        return .ready
    }
    func status(_ id: UUID?) -> NetworkSessionReply { statusReads += 1; return current }
    func stop(_ id: UUID, revision: UInt64) -> NetworkSessionReply { stops += 1; current = idle; return idle }
    func check(_ settings: SettingsSnapshot, worker: WorkerClient, withService: Bool) async throws -> String { throw ServiceClientError.unavailable }
    func start(_ idleToken: UUID, settings: SettingsSnapshot, worker: WorkerClient, interactive: Bool,
               authorize: @escaping @Sendable () async throws -> Void) async throws -> NetworkSessionReply { throw ServiceClientError.unavailable }
    func control(_ request: SessionControlRequest) async throws -> SessionControlReply { throw ServiceClientError.unavailable }
    func prepare(_ action: ServiceInstallationAction) throws { throw ServiceClientError.unavailable }
}

@MainActor final class HostShutdownTests: XCTestCase {
    private func fixture(_ body: (FreeV6HostCoordinator, ShutdownBackend) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-shutdown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "dev.freev6.shutdown-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let location = WorkerLocation(executable: root.appendingPathComponent("missing-worker"), data: root.appendingPathComponent("data"),
            resources: root, cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        let backend = try ShutdownBackend()
        let host = FreeV6HostCoordinator(location: location, defaults: defaults, backend: backend, isolated: true, notices: nil)
        _ = await host.snapshot()
        do { try await body(host, backend) }
        catch {
            await backend.repair()
            try? await host.shutdown()
            throw error
        }
        await backend.repair()
        try await host.shutdown()
    }

    private func running() throws -> NetworkSessionReply {
        try JSONDecoder().decode(NetworkSessionReply.self, from: JSONSerialization.data(withJSONObject: [
            "protocolVersion": ServiceProtocolVersion.current, "requestID": UUID().uuidString,
            "phase": "running", "sessionID": UUID().uuidString, "revision": 1,
            "settingsRevision": 1, "credentialRevision": UUID().uuidString]))
    }

    func testIncompleteInstallationAndMissingNoticesDoNotTrapQuit() async throws {
        try await fixture { host, backend in
            XCTAssertFalse(host.settings.accepted)
            XCTAssertNil(host.settings.startup.notices)
            XCTAssertFalse(host.network.mayOwnSession)
            XCTAssertEqual(host.service, .needsRepair)
            try await host.shutdown()
            let reads = await backend.healthReads, status = await backend.statusReads, stops = await backend.stops
            XCTAssertEqual(reads, 2) // Startup and a fresh check before quitting.
            XCTAssertEqual(status, 0)
            XCTAssertEqual(stops, 0)
        }
    }

    func testBrokenInstallationStillBlocksQuitWithAnOwnedSession() async throws {
        try await fixture { host, _ in
            let active = try running()
            await host.network.refresh { _ in active }
            do { try await host.shutdown(); XCTFail("An owned session still requires recovery") }
            catch InstallationError.inconsistentInstallation { }
            XCTAssertTrue(host.network.mayOwnSession)
        }
    }

    func testBrokenInstallationStillBlocksUpdateWithoutAnOwnedSession() async throws {
        try await fixture { host, _ in
            do { try await host.prepareForUpdate(); XCTFail("Updating still requires a healthy installation") }
            catch InstallationError.inconsistentInstallation { }
        }
    }

    func testFreshHealthCheckRecoversAReopenedSessionBeforeQuit() async throws {
        try await fixture { host, backend in
            let active = try running()
            await backend.setCurrent(active)
            XCTAssertFalse(host.network.mayOwnSession)
            try await host.shutdown()
            let stops = await backend.stops
            XCTAssertEqual(stops, 1)
            XCTAssertFalse(host.network.mayOwnSession)
        }
    }
}
