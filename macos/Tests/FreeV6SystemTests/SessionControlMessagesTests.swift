import XCTest
@testable import FreeV6System

final class SessionControlMessagesTests: XCTestCase {
    private let target = SessionControlTarget(sessionID: UUID(), revision: 1)
    private let encoder = JSONEncoder()

    func testMenusCanOnlyRequestKnownActionsAndGroups() throws {
        let select = SessionControlRequest(target, .select, token: UUID(), group: .access, member: "A")
        let data = try encoder.encode(select)
        XCTAssertEqual(try SessionControlRequest.decode(data).requestID, select.requestID)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value): (String, Any) in [("url", "https://example.invalid"), ("group", "GLOBAL"),
                                            ("token", NSNull()), ("protocolVersion", 5)] {
            var modified = fields
            modified[key] = value
            XCTAssertThrowsError(try SessionControlRequest.decode(JSONSerialization.data(withJSONObject: modified)))
        }
        let delayWithToken = SessionControlRequest(target, .delay, token: UUID(), group: .access, member: "A")
        XCTAssertThrowsError(try SessionControlRequest.decode(encoder.encode(delayWithToken)))
    }

    func testLateReplyCannotChangeANewerMenuRequest() throws {
        let first = SessionControlRequest(target, .setMode, token: UUID(), mode: .global)
        let second = SessionControlRequest(target, .setMode, token: UUID(), mode: .rule)
        let running = SessionControlSnapshot(token: UUID(), mode: .global, groups: [])
        let reply = try encoder.encode(SessionControlReply(first, state: running))
        XCTAssertEqual(try SessionControlReply.decode(reply, for: first).state?.mode, .global)
        XCTAssertThrowsError(try SessionControlReply.decode(reply, for: second))
        let unconfirmed = try encoder.encode(SessionControlReply(second, state: running))
        XCTAssertThrowsError(try SessionControlReply.decode(unconfirmed, for: second))
    }

    func testUnhealthyPreferenceCannotConfirmASwitchOrReturnToAutomatic() throws {
        let nodes = SessionNodeList(group: .access, selected: "A", preferred: "B", automatic: true, members: ["A", "B"])
        let running = SessionControlSnapshot(token: UUID(), mode: .rule, groups: [nodes])
        let select = SessionControlRequest(target, .select, token: UUID(), group: .access, member: "B")
        let unpin = SessionControlRequest(target, .unpin, token: UUID())
        for request in [select, unpin] {
            let reply = try encoder.encode(SessionControlReply(request, state: running))
            XCTAssertThrowsError(try SessionControlReply.decode(reply, for: request))
        }
        let automatic = SessionNodeList(group: .access, selected: "A", preferred: nil, automatic: true, members: ["A", "B"])
        let cleared = SessionControlSnapshot(token: UUID(), mode: .rule, groups: [automatic])
        let reply = try encoder.encode(SessionControlReply(unpin, state: cleared))
        XCTAssertEqual(try SessionControlReply.decode(reply, for: unpin).state?.groups.first?.selected, "A")
    }
}
