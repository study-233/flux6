import Foundation
import XCTest
import FreeV6Business
import FreeV6Desktop
@testable import FreeV6Host

private actor AutoCredentialStorage: VersionedSecretStorage {
    private var item: SecretSnapshot?
    func read() -> SecretSnapshot? { item }
    func read(interactionAllowed: Bool) -> SecretSnapshot? { item }
    func write(_ data: Data, expectedRevision: UUID?) throws -> SecretSnapshot {
        guard item?.revision == expectedRevision else { throw CredentialError.conflict }
        let value = SecretSnapshot(revision: UUID(), data: data); item = value; return value
    }
    func delete(expectedRevision: UUID) throws {
        guard item?.revision == expectedRevision else { throw CredentialError.conflict }
        item = nil
    }
}

private actor AutoRegistrationCount {
    var value = 0
    func increment() { value += 1 }
}

@MainActor final class HostAutomaticCredentialTests: XCTestCase {
    func testLiveConfigurationAutomaticallyRegistersAndSettingsReuseTheSameAccount() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let binary = env["FREEV6_WORKER_TEST_BINARY"], let runtimePath = env["FREEV6_RUNTIME_FIXTURES_DIR"],
              let geoPath = env["FREEV6_GEODATA_FIXTURES_DIR"] else { throw XCTSkip("Requires worker and pinned resource fixtures") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Runtime: Decodable {
            struct Asset: Decodable { let os: String; let arch: String; let archive: String; let sha256: String }
            let assets: [Asset]
        }
        struct Geo: Decodable { struct Asset: Decodable { let name: String }; let revision: String; let assets: [Asset] }
        let decoder = JSONDecoder()
        let catalog = try decoder.decode(Runtime.self, from: Data(contentsOf: repo.appendingPathComponent("internal/mihomo/runtime-assets.json")))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let asset = try XCTUnwrap(catalog.assets.first { $0.os == "darwin" && $0.arch == architecture })
        let geo = try decoder.decode(Geo.self, from: Data(contentsOf: repo.appendingPathComponent("internal/mihomo/geodata-assets.json")))
        let credential = try decoder.decode(WarpCredential.self, from: Data(contentsOf: repo.appendingPathComponent("shared/fixtures/warp-credential.json")))
        let root = repo.appendingPathComponent("build/host-auto-credential/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = WorkerLocation(executable: URL(fileURLWithPath: binary), data: root.appendingPathComponent("data"),
            resources: root.appendingPathComponent("resources"), cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        let archive = location.cache.appendingPathComponent("runtime/\(asset.sha256)/\(asset.archive)")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: runtimePath).appendingPathComponent(asset.archive), to: archive)
        let seeds = location.resources.appendingPathComponent("Geodata/" + geo.revision)
        try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
        for item in geo.assets {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: geoPath).appendingPathComponent(item.name), to: seeds.appendingPathComponent(item.name))
        }
        let worker = WorkerClient(location: location), counter = AutoRegistrationCount()
        let registration = WarpRegistration(vault: WarpCredentialVault(storage: AutoCredentialStorage())) { _, _ in
            await counter.increment(); return credential
        }
        let session = LiveHostSession(bundle: .main, location: location, registration: registration)
        let suite = "dev.freev6.auto-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let logs = DesktopLogs(directory: location.logs)
        let settings = HostSettings(worker: worker, defaults: defaults, logs: logs, preview: false,
                                    noticesDirectory: nil, registration: registration)
        do {
            let saved = try await worker.settings()
            _ = try await worker.runtimeStatus(); _ = try await worker.prepareGeodata { _ in }
            let first = try await session.check(saved, worker: worker, withService: false)
            XCTAssertTrue(first.contains("已通过本机配置检查"))
            await settings.refreshAccountSilently()
            XCTAssertNotNil(settings.account); XCTAssertFalse(settings.pendingCredential)
            let account = settings.account
            _ = try await session.check(saved, worker: worker, withService: false)
            await settings.refreshAccountSilently()
            XCTAssertEqual(account, settings.account)
            let count = await counter.value
            XCTAssertEqual(count, 1)
            await worker.shutdown(); await logs.finishWrites()
        } catch {
            await worker.shutdown(); await logs.finishWrites(); throw error
        }
    }
}
