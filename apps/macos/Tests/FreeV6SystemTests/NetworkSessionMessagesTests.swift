import XCTest
@testable import FreeV6System

final class NetworkSessionMessagesTests: XCTestCase {
    func testReplyBindsEachPhaseToItsExactFieldsAndRequest() throws {
        let id = UUID()
        let reply: [String: Any] = ["protocolVersion": ServiceProtocolVersion.current, "phase": "occupied", "requestID": id.uuidString]
        func decode(_ extra: [String: Any], id expected: UUID) throws -> NetworkSessionReply {
            let fields = reply.merging(extra) { _, new in new }
            return try NetworkSessionReply.decode(JSONSerialization.data(withJSONObject: fields), id: expected)
        }
        XCTAssertEqual(try decode([:], id: id).phase, .occupied)
        XCTAssertThrowsError(try decode([:], id: UUID()))
        for extra: [String: Any] in [["sessionID": UUID().uuidString], ["idleToken": UUID().uuidString],
                                       ["phase": "stopped"], ["phase": "running"], ["protocolVersion": 4]] {
            XCTAssertThrowsError(try decode(extra, id: id))
        }
        let owned: [String: Any] = ["phase": "running", "sessionID": UUID().uuidString, "revision": 1,
                                    "settingsRevision": 1, "credentialRevision": UUID().uuidString]
        XCTAssertEqual(try decode(owned, id: id).revision, 1)
        XCTAssertThrowsError(try decode(owned.merging(["revision": 0]) { _, new in new }, id: id))
        XCTAssertThrowsError(try decode(owned.merging(["idleToken": UUID().uuidString]) { _, new in new }, id: id))
    }

    func testStopRequiresIDAndRevisionAndHeartbeatCannotSupplyRevision() throws {
        let id = UUID()
        for query in [NetworkSessionQuery(), NetworkSessionQuery(sessionID: id)] {
            let bytes = try JSONEncoder().encode(query)
            XCTAssertNoThrow(try NetworkSessionQuery.decode(bytes, stopping: false))
            XCTAssertThrowsError(try NetworkSessionQuery.decode(bytes, stopping: true))
        }
        let stop = try JSONEncoder().encode(NetworkSessionQuery(sessionID: id, revision: 2))
        XCTAssertEqual(try NetworkSessionQuery.decode(stop, stopping: true).sessionID, id)
        XCTAssertThrowsError(try NetworkSessionQuery.decode(stop, stopping: false))
        let zero = try JSONEncoder().encode(NetworkSessionQuery(sessionID: id, revision: 0))
        XCTAssertThrowsError(try NetworkSessionQuery.decode(zero, stopping: true))
    }
}
