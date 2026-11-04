import Darwin
import Foundation
import XCTest
import FreeV6Configuration
@testable import FreeV6System

final class ServiceConfigurationTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func request() throws -> ConfigurationCheckRequest {
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-business-configuration.json"))
        let business = try JSONDecoder().decode(BusinessConfiguration.self, from: data)
        return ConfigurationCheckRequest(runtimeID: ApprovedResourceCatalog.native.first { $0.architecture != nil }!.id,
            geodataID: String(ApprovedResourceCatalog.native.first { $0.architecture == nil }!.id.split(separator: "/")[0]),
            settingsRevision: 31, credentialRevision: UUID(), configuration: business)
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = repository.appendingPathComponent("build/service-configuration-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testRequestBoundsResourceBindingAndSystemFieldRejection() throws {
        let request = try request(), bytes = try JSONEncoder().encode(request)
        let decoded = try ServiceMessages.decodeConfiguration(bytes)
        XCTAssertEqual(decoded.requestID, request.requestID)
        XCTAssertEqual(decoded.settingsRevision, 31)
        XCTAssertEqual(String(reflecting: decoded), "ConfigurationCheckRequest(redacted)")
        XCTAssertThrowsError(try ServiceMessages.decodeConfiguration(Data(repeating: 32, count: ServiceMessages.maximumConfigurationBytes + 1)))
        let source = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for key in ["path", "uid", "secret", "sessionID", "controller"] {
            var bad = source; bad[key] = "sensitive-marker"
            XCTAssertThrowsError(try ServiceMessages.decodeConfiguration(JSONSerialization.data(withJSONObject: bad))) { error in
                XCTAssertFalse(error.localizedDescription.contains("sensitive-marker"))
            }
        }
        for (key, value) in [("runtimeID", "other-version"), ("geodataID", "geodata"), ("credentialRevision", "not-a-uuid")] {
            var bad = source; bad[key] = value
            XCTAssertThrowsError(try ServiceMessages.decodeConfiguration(JSONSerialization.data(withJSONObject: bad)))
        }
        var old = source; old["protocolVersion"] = 2
        XCTAssertThrowsError(try ServiceMessages.decodeConfiguration(JSONSerialization.data(withJSONObject: old)))
        for key in ["tun", "dns", "mixed-port", "external-controller", "external-controller-unix", "secret", "profile"] {
            var bad = source, business = bad["configuration"] as! [String: Any]
            business[key] = "sensitive-marker"; bad["configuration"] = business
            XCTAssertThrowsError(try ServiceMessages.decodeConfiguration(JSONSerialization.data(withJSONObject: bad))) { error in
                XCTAssertFalse(error.localizedDescription.contains("sensitive-marker"))
            }
        }
    }

    func testServicePolicyPreservesBusinessAndOwnsAllSystemFields() throws {
        let business = try request().configuration
        let id = UUID(), result = try ServiceConfigurationAssembler.assemble(business, sessionID: id)
        XCTAssertEqual(String(reflecting: result), "AssembledServiceConfiguration(redacted)")
        let document = try JSONSerialization.jsonObject(with: result.data) as! [String: Any]
        let original = try JSONSerialization.jsonObject(with: business.encoded()) as! NSDictionary
        let projection = document.filter { original[$0.key] != nil } as NSDictionary
        XCTAssertEqual(projection, original)
        let socket = try XCTUnwrap(document["external-controller-unix"] as? String)
        XCTAssertEqual(socket, ServiceConfigurationAssembler.sessions + "/" + id.uuidString + "/c.sock")
        XCTAssertLessThan(socket.utf8.count, 104)
        XCTAssertEqual(document["external-controller"] as? String, "")
        XCTAssertEqual(document["external-controller-tls"] as? String, "")
        XCTAssertEqual(document["allow-lan"] as? Bool, false)
        XCTAssertEqual(document["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(document["geo-auto-update"] as? Bool, false)
        let dns = document["dns"] as! [String: Any]
        XCTAssertEqual(dns["listen"] as? String, "127.0.0.1:1053")
        let check = DNSResolverPolicy.hostsPattern(id)
        XCTAssertEqual(document["hosts"] as? [String: String], [check: DNSResolverPolicy.checkAnswer])
        XCTAssertTrue((dns["fake-ip-filter"] as? [String])?.contains(check) == true)
        XCTAssertNotNil(dns["nameserver-policy"])
        let tun = document["tun"] as! [String: Any]
        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertNil(tun["device"])
        XCTAssertNil(tun["strict-route"])
        let geox = document["geox-url"] as! [String: String]
        XCTAssertEqual(geox.count, 3)
        XCTAssertTrue(geox.values.allSatisfy { $0.contains("fb6bd25ca61dd918d36b0f61b4bad67dfc278bcf/") })
        let secret = try XCTUnwrap(document["secret"] as? String)
        XCTAssertEqual(secret.count, 64)
        let second = try JSONSerialization.jsonObject(with: ServiceConfigurationAssembler.assemble(business, sessionID: UUID()).data) as! [String: Any]
        XCTAssertNotEqual(secret, second["secret"] as? String)
        XCTAssertNotEqual(socket, second["external-controller-unix"] as? String)
        XCTAssertNil(document["token"])
        XCTAssertNil(document["deviceId"])
    }

    func testClientRejectsOldOrUnvalidatedCoreAcknowledgements() throws {
        let request = try request()
        let bytes = try JSONEncoder().encode(ConfigurationCheckReply(request))
        XCTAssertTrue(try ServiceClient.decodeConfigurationReply(bytes, request: request).coreValidated)
        let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for (key, value) in [("protocolVersion", 3 as Any), ("coreValidated", false as Any),
                             ("requestID", UUID().uuidString as Any), ("settingsRevision", request.settingsRevision + 1 as Any)] {
            var invalid = original; invalid[key] = value
            XCTAssertThrowsError(try ServiceClient.decodeConfigurationReply(JSONSerialization.data(withJSONObject: invalid), request: request))
        }
        var missing = original; missing.removeValue(forKey: "coreValidated")
        XCTAssertThrowsError(try ServiceClient.decodeConfigurationReply(JSONSerialization.data(withJSONObject: missing), request: request))
    }

    func testServiceCheckRequiresIndependentResourcesAndDoesNotPersistSecrets() throws {
        try fixture { root in
            let store = try ServiceResourceStore(path: root.appendingPathComponent("resources").path, owner: geteuid())
            let bytes = try JSONEncoder().encode(request())
            XCTAssertThrowsError(try store.checkConfiguration(bytes, clientUID: geteuid())) { error in
                guard case ResourceStoreError.integrity = error else { return XCTFail("Unexpected error") }
            }
            XCTAssertThrowsError(try store.checkConfiguration(bytes, clientUID: 0))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["resources", "sessions", "network.lock"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path), [])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("resources").path), ["resources.lock"])
        }
    }

    func testCacheLocatorUsesCompiledNamesAndRejectsSymlinkAndWritableFiles() throws {
        try fixture { root in
            let asset = ApprovedResourceCatalog.native.first { $0.architecture != nil }!
            let folder = root.appendingPathComponent("runtime/" + asset.archiveSHA256!)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(asset.archiveName!)
            try Data("descriptor test only; service will reject this content".utf8).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            let handle = try ServiceResourceTransfer.openSource(cache: root, asset: asset)
            defer { try? handle.close() }
            try FileManager.default.removeItem(at: file)
            XCTAssertFalse((try handle.readToEnd() ?? Data()).isEmpty) // FD survives path replacement.
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
            XCTAssertThrowsError(try ServiceResourceTransfer.openSource(cache: root, asset: asset))
            try FileManager.default.removeItem(at: file)
            try Data().write(to: file)
            XCTAssertEqual(chmod(file.path, 0o622), 0)
            XCTAssertThrowsError(try ServiceResourceTransfer.openSource(cache: root, asset: asset))
            XCTAssertThrowsError(try ApprovedResourceCatalog.requirePair(runtimeID: asset.id, geodataID: ""))
        }
    }
}
