import Foundation
import XCTest
@testable import FreeV6Business

final class ConfigurationPreparationTests: XCTestCase {
    func testRealWorkerBindsSettingsCredentialsAndVerifiedResourcesWithoutWritingSecrets() async throws {
        guard let binary = ProcessInfo.processInfo.environment["FREEV6_WORKER_TEST_BINARY"],
              let runtimeFixtures = ProcessInfo.processInfo.environment["FREEV6_RUNTIME_FIXTURES_DIR"],
              let geodataFixtures = ProcessInfo.processInfo.environment["FREEV6_GEODATA_FIXTURES_DIR"] else {
            throw XCTSkip("Set worker binary and official resource fixtures for configuration integration")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct RuntimeCatalog: Decodable {
            struct Asset: Decodable { let os: String; let arch: String; let archive: String; let sha256: String }
            let assets: [Asset]
        }
        struct GeoCatalog: Decodable { struct Asset: Decodable { let name: String }; let revision: String; let assets: [Asset] }
        let decoder = JSONDecoder()
        let runtime = try decoder.decode(RuntimeCatalog.self, from: Data(contentsOf: repository.appendingPathComponent("internal/mihomo/runtime-assets.json")))
        let geo = try decoder.decode(GeoCatalog.self, from: Data(contentsOf: repository.appendingPathComponent("internal/mihomo/geodata-assets.json")))
        let credential = try decoder.decode(WarpCredential.self, from: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-credential.json")))
        let sample = try decoder.decode(SettingsSnapshot.self, from: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/worker-settings.json")))
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let asset = try XCTUnwrap(runtime.assets.first { $0.os == "darwin" && $0.arch == arch })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-configuration-test-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("resources"), cache = root.appendingPathComponent("cache"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkerClient(location: WorkerLocation(executable: URL(fileURLWithPath: binary), data: data, resources: resources,
            cache: cache, logs: root.appendingPathComponent("logs")))
        let revision = UUID(), tunnel = try credential.tunnelCredential()
        do {
            let defaults = try await client.settings()
            do {
                _ = try await client.prepareConfiguration(settings: defaults, credentialRevision: revision, tunnel: tunnel, runtimeId: "missing", geodataId: "missing")
                XCTFail("unprepared resources accepted")
            } catch let failure as WorkerRemoteError { XCTAssertEqual(failure.code, -32006) }
            let archive = cache.appendingPathComponent("runtime/\(asset.sha256)/\(asset.archive)")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: runtimeFixtures).appendingPathComponent(asset.archive), to: archive)
            let seeds = resources.appendingPathComponent("Geodata/\(geo.revision)")
            try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
            for file in geo.assets {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: geodataFixtures).appendingPathComponent(file.name), to: seeds.appendingPathComponent(file.name))
            }
            let core = try await client.runtimeStatus(), geodata = try await client.prepareGeodata { _ in }
            let saved = try await client.save(sample.settings, revision: defaults.revision)
            let prepared = try await client.prepareConfiguration(settings: saved, credentialRevision: revision, tunnel: tunnel,
                runtimeId: core.resourceId, geodataId: geodata.resourceId)
            XCTAssertEqual(prepared.settingsRevision, saved.revision)
            XCTAssertEqual(prepared.credentialRevision, revision)
            XCTAssertEqual(prepared.configuration.proxyCount, 28)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.configuration.encoded()) as? NSDictionary)
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-business-configuration.json"))) as? NSDictionary)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(String(reflecting: prepared), "PreparedConfiguration(redacted)")
            do {
                _ = try await client.prepareConfiguration(settings: saved, credentialRevision: revision, tunnel: tunnel,
                    runtimeId: "wrong-runtime", geodataId: geodata.resourceId)
                XCTFail("mismatched resource binding accepted")
            } catch { XCTAssertFalse(error.localizedDescription.contains(credential.device.privateKey)) }
            _ = try await client.save(sample.settings, revision: saved.revision)
            do {
                _ = try await client.prepareConfiguration(settings: saved, credentialRevision: revision, tunnel: tunnel,
                    runtimeId: core.resourceId, geodataId: geodata.resourceId)
                XCTFail("stale settings accepted")
            } catch let failure as WorkerRemoteError { XCTAssertEqual(failure.code, -32004) }
            let baseline = try await client.settings()
            let chainKey = Data(repeating: 37, count: 32)
            let imported = try await client.importChain(from: .file(repository.appendingPathComponent("shared/fixtures/chain-proxies.yaml")),
                                                        settings: baseline, key: chainKey)
            XCTAssertEqual(imported.chain?.names, ["Socks", "HTTP", "Shadowsocks", "Trojan", "VLESS", "VMess"])
            XCTAssertEqual(imported.chain?.enabled, true)
            await client.shutdown()
            let restarted = try await client.settings()
            XCTAssertEqual(restarted, imported)
            do {
                _ = try await client.prepareConfiguration(settings: restarted, credentialRevision: revision, tunnel: tunnel,
                    runtimeId: core.resourceId, geodataId: geodata.resourceId)
                XCTFail("enabled chain silently fell back to WARP")
            } catch let failure as WorkerRemoteError { XCTAssertEqual(failure.code, -32008) }
            let withChain = try await client.prepareConfiguration(settings: restarted, credentialRevision: revision, tunnel: tunnel,
                runtimeId: core.resourceId, geodataId: geodata.resourceId, chainKey: chainKey)
            XCTAssertEqual(withChain.configuration.proxyCount, 34)
            XCTAssertThrowsError(try withChain.configuration.requireWarp(tunnel, mode: restarted.settings.mode.rawValue))
            let chainDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: withChain.configuration.encoded()) as? [String: Any])
            let rules = try XCTUnwrap(chainDocument["rules"] as? [String])
            XCTAssertEqual(Array(rules.suffix(2)), ["MATCH,🔗 链式代理", "NETWORK,UDP,REJECT"])
            let preferencesWithChain = try String(contentsOf: data.appendingPathComponent("proxy-preferences.json"))
            XCTAssertFalse(preferencesWithChain.contains("synthetic-only"))
            XCTAssertFalse(preferencesWithChain.contains(chainKey.base64EncodedString()))
            let bad = root.appendingPathComponent("invalid.yaml")
            try Data("proxies: [{name: bad, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic-only, plugin: arbitrary}]".utf8).write(to: bad)
            do {
                _ = try await client.importChain(from: .file(bad), settings: restarted, key: chainKey)
                XCTFail("unreviewed plugin accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("第 1 个节点"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-only"))
            }
            let retained = try await client.settings()
            XCTAssertEqual(retained, restarted)
            let off = try await client.setChainEnabled(false, settings: retained)
            let withoutChain = try await client.prepareConfiguration(settings: off, credentialRevision: revision, tunnel: tunnel,
                runtimeId: core.resourceId, geodataId: geodata.resourceId)
            XCTAssertEqual(withoutChain.configuration.proxyCount, 28)
            let noticeFile = data.appendingPathComponent("maintainer-notice.json")
            func writeGate(_ allowed: Bool) throws {
                let record: [String: Any] = ["fetchedAt": ISO8601DateFormatter().string(from: Date()), "cloudProfile": allowed, "items": []]
                try JSONSerialization.data(withJSONObject: record).write(to: noticeFile, options: .atomic)
            }
            try writeGate(true)
            let notice = try await client.maintainerNotice(refresh: false)
            XCTAssertTrue(notice.cloudAllowed)
            let campusFile = repository.appendingPathComponent("shared/fixtures/chain-proxies.yaml")
            let campusKey = Data(repeating: 23, count: 32)
            let campus = try await client.importCloud(from: .file(campusFile), settings: off, key: campusKey)
            XCTAssertEqual(campus.chain, off.chain)
            XCTAssertEqual(campus.cloud?.ignored, ["external-controller", "rules"])
            do {
                _ = try await client.setChainEnabled(true, settings: campus)
                XCTFail("both exits enabled")
            } catch let failure as WorkerRemoteError { XCTAssertEqual(failure.code, -32602) }
            let direct = try await client.prepareCloud(settings: campus, key: campusKey, runtimeId: core.resourceId, geodataId: geodata.resourceId)
            XCTAssertTrue(direct.configuration.isCampusProfile)
            XCTAssertEqual(direct.configuration.proxyCount, 6)
            XCTAssertEqual(direct.credentialRevision, campus.cloud?.id)
            do {
                _ = try await client.importCloud(from: .file(bad), settings: campus, key: campusKey)
                XCTFail("unsafe campus plugin saved")
            } catch { XCTAssertTrue(error.localizedDescription.contains("第 1 个节点")) }
            let current = try await client.settings()
            XCTAssertEqual(current, campus)
            let manyFile = root.appendingPathComponent("many.yaml")
            func writeNodes(count: Int) throws {
                let rows = (1...count).map { "  - {name: campus-\($0), type: http, server: 192.0.2.1, port: 443}" }
                try ("proxies:\n" + rows.joined(separator: "\n")).write(to: manyFile, atomically: true, encoding: .utf8)
            }
            try writeNodes(count: 200)
            let full = try await client.importCloud(from: .file(manyFile), settings: current, key: campusKey)
            let many = try await client.prepareCloud(settings: full, key: campusKey, runtimeId: core.resourceId, geodataId: geodata.resourceId)
            XCTAssertEqual(many.configuration.proxyCount, 200)
            try writeNodes(count: 201)
            do {
                _ = try await client.importCloud(from: .file(manyFile), settings: full, key: campusKey)
                XCTFail("oversized campus profile accepted")
            } catch let failure as WorkerRemoteError { XCTAssertEqual(failure.code, -32602) }
            try writeGate(false)
            do {
                _ = try await client.prepareCloud(settings: full, key: campusKey, runtimeId: core.resourceId, geodataId: geodata.resourceId)
                XCTFail("revoked campus profile still prepared")
            } catch let failure as WorkerRemoteError { XCTAssertTrue(failure.message.contains("未开放")) }
            let campusCleared = try await client.changeCloud(.clear, settings: full)
            XCTAssertNil(campusCleared.cloud)
            let cleared = try await client.clearChain(settings: campusCleared)
            XCTAssertNil(cleared.chain)
            let files = try FileManager.default.contentsOfDirectory(atPath: data.path)
            XCTAssertEqual(Set(files), Set(["worker.lock", "proxy-preferences.json", "maintainer-notice.json"]))
            let preferences = try String(contentsOf: data.appendingPathComponent("proxy-preferences.json"))
            XCTAssertFalse(preferences.contains(credential.device.privateKey))
            XCTAssertFalse(preferences.contains(credential.device.token))
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }
}
