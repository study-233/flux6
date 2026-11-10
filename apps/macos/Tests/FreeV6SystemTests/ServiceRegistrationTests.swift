import Foundation
import XCTest
@testable import FreeV6System

final class ServiceRegistrationTests: XCTestCase {
    func testIdentityRejectsInjectedRequirementsAndMalformedHashes() {
        for hash in ["", "1234", String(repeating: "g", count: 40), "\" or anchor apple"] {
            XCTAssertThrowsError(try CodeIdentity(identifier: "client", cdHash: hash))
        }
        let payload = Data("{\"identifier\":\"client\",\"cdHash\":\"bad\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CodeIdentity.self, from: payload))
    }

    func testRegistrationBindsCodeIdentityToUser() throws {
        let first = try CodeIdentity(identifier: "client", cdHash: String(repeating: "1", count: 40))
        let second = try CodeIdentity(identifier: "client", cdHash: String(repeating: "2", count: 40))
        let registration = try ServiceRegistration(service: first, clients: [
            RegisteredClient(uid: 501, identity: first), RegisteredClient(uid: 502, identity: second),
        ])
        XCTAssertTrue(registration.requirement(for: 501)!.contains(first.cdHash))
        XCTAssertFalse(registration.requirement(for: 501)!.contains(second.cdHash))
        XCTAssertNil(registration.requirement(for: 503))
        XCTAssertEqual(try ServiceRegistration.decode(JSONEncoder().encode(registration)), registration)
    }

    func testRegistrationRejectsUnknownSchemaAndEmptyClients() throws {
        let identity = try CodeIdentity(identifier: "client", cdHash: String(repeating: "a", count: 40))
        XCTAssertThrowsError(try ServiceRegistration(service: identity, clients: []))
        let registration = try ServiceRegistration(service: identity, clients: [RegisteredClient(uid: 501, identity: identity)])
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as! [String: Any]
        value["schema"] = 99
        XCTAssertThrowsError(try ServiceRegistration.decode(JSONSerialization.data(withJSONObject: value)))
        value["schema"] = 1
        value["clients"] = []
        XCTAssertThrowsError(try ServiceRegistration.decode(JSONSerialization.data(withJSONObject: value)))
        XCTAssertThrowsError(try ServiceRegistration.decode(Data(repeating: 32, count: ServiceRegistration.maximumBytes + 1)))
    }
}
