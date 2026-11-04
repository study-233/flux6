import Foundation
import XCTest
@testable import FreeV6Configuration

final class BusinessConfigurationTests: XCTestCase {
    private func fixture() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("shared/fixtures/warp-business-configuration.json"))
    }
    private func decode(_ object: [String: Any]) throws -> BusinessConfiguration {
        try JSONDecoder().decode(BusinessConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testSharedGoConfigurationRoundTripAndRedactedDescription() throws {
        let data = try fixture()
        let result = try JSONDecoder().decode(BusinessConfiguration.self, from: data)
        XCTAssertEqual(result.mode, "global")
        XCTAssertEqual(result.proxyCount, 28)
        XCTAssertEqual(String(reflecting: result), "BusinessConfiguration(redacted)")
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: result.encoded()) as? NSDictionary)
        XCTAssertEqual(source, restored)
        let proxy = try XCTUnwrap((source["proxies"] as? [[String: Any]])?.first)
        let tunnel = TunnelCredential(privateKey: proxy["private-key"] as! String, peerPublicKey: proxy["public-key"] as! String,
            ipv4: proxy["ip"] as! String, ipv6: proxy["ipv6"] as! String)
        XCTAssertNoThrow(try result.requireWarp(tunnel, mode: "global"))
        XCTAssertThrowsError(try result.requireWarp(tunnel, mode: "direct"))
        let other = TunnelCredential(privateKey: tunnel.privateKey, peerPublicKey: tunnel.peerPublicKey, ipv4: "172.16.0.9", ipv6: tunnel.ipv6)
        XCTAssertThrowsError(try result.requireWarp(other, mode: "global"))
        XCTAssertEqual(String(reflecting: tunnel), "TunnelCredential(redacted)")
        for mapped in ["::ffff:172.16.0.2", "0:0:0:0:0:ffff:ac10:2"] {
            XCTAssertThrowsError(try TunnelCredential(privateKey: tunnel.privateKey, peerPublicKey: tunnel.peerPublicKey,
                ipv4: tunnel.ipv4, ipv6: mapped).validated())
        }
        XCTAssertNoThrow(try TunnelCredential(privateKey: tunnel.privateKey, peerPublicKey: tunnel.peerPublicKey,
            ipv4: tunnel.ipv4, ipv6: "::ffff:1:2:3").validated())
    }
    func testRejectsSystemFieldsPluginsPathsProvidersAndInvalidGraph() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["tun"] = ["enable": true] },
            { $0["secret"] = "sensitive-controller-value" },
            { $0["external-controller"] = "0.0.0.0:9090" },
            { $0["mode"] = "invalid" },
            { value in var p = value["proxies"] as! [[String: Any]]; p[0]["plugin"] = "script"; value["proxies"] = p },
            { value in var p = value["proxies"] as! [[String: Any]]; p[0]["private-key"] = "sensitive-bad-key"; value["proxies"] = p },
            { value in var p = value["proxies"] as! [[String: Any]]; p[0]["port"] = 443.5; value["proxies"] = p },
            { value in var p = value["proxies"] as! [[String: Any]]; p[0]["type"] = "direct"; value["proxies"] = p },
            { value in var p = value["proxies"] as! [[String: Any]]; p[0]["ipv6"] = "::ffff:172.16.0.2"; value["proxies"] = p },
            { value in var g = value["proxy-groups"] as! [[String: Any]]; g[0]["proxies"] = [g[0]["name"]!]; value["proxy-groups"] = g },
            { value in var g = value["proxy-groups"] as! [[String: Any]]; g[0]["proxies"] = ["missing"]; value["proxy-groups"] = g },
            { value in var p = value["rule-providers"] as! [String: [String: Any]]; p["rule00"]!["url"] = "https://example.com/other"; value["rule-providers"] = p },
            { value in var p = value["rule-providers"] as! [String: [String: Any]]; p["rule00"]!["path"] = "/etc/private"; value["rule-providers"] = p },
            { $0["rules"] = ["SCRIPT,arbitrary,REJECT", "MATCH,🚀 节点选择"] },
            { $0["rules"] = ["DOMAIN-SUFFIX,invalid_domain.example,DIRECT", "MATCH,🚀 节点选择"] },
            { $0["rules"] = ["IP-CIDR6,2001:db8::/129,DIRECT,no-resolve", "MATCH,🚀 节点选择"] },
            { $0["rules"] = Array(repeating: "MATCH,🚀 节点选择", count: 6001) },
        ]
        for (index, mutate) in mutations.enumerated() {
            var value = original; mutate(&value)
            XCTAssertThrowsError(try decode(value), "mutation \(index)") { error in
                XCTAssertFalse(error.localizedDescription.contains("sensitive-"))
            }
        }
    }
}
