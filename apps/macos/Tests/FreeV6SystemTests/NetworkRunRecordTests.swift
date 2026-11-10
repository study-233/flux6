import Darwin
import Foundation
import XCTest
@testable import FreeV6System

final class NetworkRunRecordTests: XCTestCase {
    private func journal() -> [String: Any] {
        let run: [String: Any] = [
            "stage": "active", "revision": 5, "ruleFiles": ["rule00.list", "rule19.list"],
            "tunnel": ["name": "utun12", "index": 34],
            "origin": ["bootID": UUID().uuidString, "ownerUID": 0, "groupID": 1234]
        ]
        return ["schema": 3, "phase": "network", "sessionID": UUID().uuidString, "clientUID": 501,
                "credentialRevision": UUID().uuidString, "settingsRevision": 1, "policyVersion": 2,
                "configurationSHA256": String(repeating: "a", count: 64), "runtimeID": "runtime",
                "geodataID": "geodata", "run": run]
    }

    func testRunningSchemaIsDisjointFromPreparationAndCheck() throws {
        let original = journal()
        func decode(_ fields: [String: Any]) throws -> PreparedSessionRecord {
            try PreparedSessionRecord.decode(JSONSerialization.data(withJSONObject: fields))
        }
        XCTAssertEqual(try decode(original).run?.tunnel, CoreTunnel(name: "utun12", index: 34))
        for (key, value) in [("schema", 1 as Any), ("schema", 2), ("phase", "prepared"), ("phase", "checking"),
                             ("check", NSNull()), ("jobLabel", "other"), ("run", NSNull())] {
            var invalid = original
            invalid[key] = value
            XCTAssertThrowsError(try decode(invalid))
        }
    }

    func testRestorationIdentityAndCleanupNamesAreStrictlyBounded() throws {
        let original = journal()
        for (key, value) in [("stage", "capturingDNS" as Any), ("stage", "finished"), ("revision", 0),
                             ("revision", 2), ("pid", 1234), ("ruleFiles", ["rule01.list", "rule01.list"]),
                             ("ruleFiles", ["../rule05.list"]), ("ruleFiles", ["rule00.list.tmp"]),
                             ("tunnel", ["name": "en0", "index": 2]), ("tunnel", ["name": "utun00", "index": 1]),
                             ("tunnel", ["name": "utun0", "index": 0]), ("tunnel", NSNull())] {
            var fields = original
            var run = original["run"] as! [String: Any]
            run[key] = value
            fields["run"] = run
            XCTAssertThrowsError(try PreparedSessionRecord.decode(JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testMatchingPeerRouteRequiresOneExplicitInterface() throws {
        let route = "   route to: 192.0.2.1\n destination: default\n  interface: utun8\n    flags: <UP>\n"
        XCTAssertEqual(CoreTunnel.routeInterfaces(route), ["utun8"])
        XCTAssertEqual(CoreTunnel.routeInterfaces(route + "  interface: en0\n"), ["utun8", "en0"])
        XCTAssertEqual(CoreTunnel.routeInterfaces("route to: utun8\n"), [])
        XCTAssertNil(try CoreTunnel.owned(by: getpid()))
    }
}
