import XCTest
import FreeV6System
@testable import FreeV6Desktop

@MainActor final class DesktopNetworkSessionTests: XCTestCase {
    private let token = UUID()
    private let id = UUID()

    private func reply(_ phase: NetworkSessionPhase, id: UUID? = nil, revision: UInt64 = 2) throws -> NetworkSessionReply {
        var fields: [String: Any] = ["protocolVersion": ServiceProtocolVersion.current, "requestID": UUID().uuidString,
                                     "phase": phase.rawValue]
        if phase == .stopped { fields["idleToken"] = token.uuidString }
        if let id {
            fields["sessionID"] = id.uuidString
            fields["revision"] = revision
            fields["credentialRevision"] = UUID().uuidString
            fields["settingsRevision"] = 1
        }
        return try JSONDecoder().decode(NetworkSessionReply.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testLatePollCannotUndoConfirmedStartOrHideHeartbeat() async throws {
        let model = DesktopNetworkSession()
        let idle = try reply(.stopped)
        let active = try reply(.running, id: id)
        await model.refresh { _ in idle }
        var suspended: CheckedContinuation<NetworkSessionReply, Never>?
        let late = Task { await model.refresh { _ in await withCheckedContinuation { suspended = $0 } } }
        while suspended == nil { await Task.yield() }
        await model.connect { value in
            XCTAssertEqual(value, self.token)
            XCTAssertEqual(model.phase, .connecting)
            await model.connect { _ in XCTFail("duplicate start"); return active }
            return active
        }
        suspended?.resume(returning: idle)
        await late.value
        XCTAssertEqual(model.phase, .running)
        await model.refresh { value in XCTAssertEqual(value, self.id); return active }
        try await model.disconnect { value, revision in
            XCTAssertEqual(value, self.id)
            XCTAssertEqual(revision, 2)
            return idle
        }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.mayOwnSession)
    }

    func testLostStartReplyAndFailedRecoveryRemainRetryableAcrossExit() async throws {
        let model = DesktopNetworkSession()
        await model.refresh { _ in try self.reply(.stopped) }
        await model.connect { _ in throw ServiceClientError.timeout }
        XCTAssertEqual(model.phase, .unknown)
        XCTAssertTrue(model.mayOwnSession)
        await model.refresh { _ in try self.reply(.running, id: self.id) }
        do {
            try await model.disconnectBeforeExit(status: { _ in try self.reply(.running, id: self.id) },
                                                 stop: { _, _ in throw ServiceClientError.timeout })
            XCTFail("an unconfirmed stop allowed quitting")
        } catch {}
        XCTAssertTrue(model.mayOwnSession)
        XCTAssertNotNil(model.error)
        await model.refresh { seen in
            XCTAssertEqual(seen, self.id)
            return try self.reply(.recoveryRequired, id: self.id, revision: 3)
        }
        XCTAssertEqual(model.phase, .recovering)
        try await model.disconnectBeforeExit(status: { _ in try self.reply(.recoveryRequired, id: self.id, revision: 3) },
                                            stop: { id, rev in
            XCTAssertEqual(id, self.id)
            XCTAssertEqual(rev, 3)
            return try self.reply(.stopped)
        })
        XCTAssertEqual(model.phase, .idle)
    }

    func testForeignSessionAndLaterSessionAreProtectedDuringQuit() async throws {
        let model = DesktopNetworkSession()
        await model.refresh { _ in try self.reply(.running, id: self.id) }
        let newer = UUID()
        do {
            try await model.disconnectBeforeExit(status: { _ in try self.reply(.running, id: newer) },
                                                 stop: { _, _ in XCTFail("wrong session stopped"); return try self.reply(.stopped) })
            XCTFail("a replacement session needs a new user decision")
        } catch {}
        try await model.disconnectBeforeExit(status: { _ in try self.reply(.occupied) },
                                             stop: { _, _ in XCTFail("foreign session stopped"); return try self.reply(.stopped) })
        XCTAssertEqual(model.phase, .occupied)
        XCTAssertFalse(model.mayOwnSession)
        XCTAssertFalse(model.canTargetSession)
    }
}
