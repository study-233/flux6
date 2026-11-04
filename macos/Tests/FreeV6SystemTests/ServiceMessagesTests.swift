import Foundation
import XCTest
@testable import FreeV6System

final class ServiceMessagesTests: XCTestCase {
    func testHandshakePreservesRequestIdentity() throws {
        let request = HandshakeRequest()
        XCTAssertEqual(try ServiceMessages.decodeHandshake(JSONEncoder().encode(request)), request)
    }

    func testUnknownProtocolIsRejected() throws {
        let data = try JSONEncoder().encode(HandshakeRequest(protocolVersion: 999))
        XCTAssertThrowsError(try ServiceMessages.decodeHandshake(data)) { error in
            guard case ServiceMessageError.incompatibleVersion(999) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOversizedHandshakeIsRejectedBeforeDecoding() {
        XCTAssertThrowsError(try ServiceMessages.decodeHandshake(Data(repeating: 32, count: 4097))) { error in
            guard case ServiceMessageError.oversized = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMissingFieldsAreRejected() {
        XCTAssertThrowsError(try ServiceMessages.decodeHandshake(Data("{}".utf8)))
    }

    func testDNSSnapshotPreservesAbsenceAndExplicitEmptyConfiguration() throws {
        let explicit = try PropertyListSerialization.data(fromPropertyList: [:], format: .binary, options: 0)
        let snapshots = [
            DNSServiceSnapshot(serviceID: "dhcp", name: "Wi-Fi", enabled: true, configuredDNS: nil),
            DNSServiceSnapshot(serviceID: "manual", name: "Ethernet", enabled: true, configuredDNS: explicit),
        ]
        let result = try JSONDecoder().decode([DNSServiceSnapshot].self, from: JSONEncoder().encode(snapshots))
        XCTAssertNil(result[0].configuredDNS)
        XCTAssertEqual(result[1].configuredDNS, explicit)
    }
}
