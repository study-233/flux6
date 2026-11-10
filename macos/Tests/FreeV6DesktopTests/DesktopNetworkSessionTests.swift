import XCTest
@testable import FreeV6System
@testable import FreeV6Desktop

@MainActor final class DesktopNetworkSessionTests: XCTestCase {
    private let token = UUID()
    private let id = UUID()

    func testUpdateChecksIdleAgainAndDoesNotStopAnotherUsersSession() async throws {
        let model = DesktopNetworkSession()
        let idle = try reply(.stopped)
        let occupied = try reply(.occupied)
        var reads = 0
        do {
            try await model.disconnectBeforeUpdate(status: { _ in
                reads += 1
                return reads == 1 ? idle : occupied
            }, stop: { _, _ in XCTFail("Foreign session must remain untouched"); return idle })
            XCTFail("Installing while another user is active should fail")
        } catch { XCTAssertEqual(model.phase, .occupied) }
        XCTAssertEqual(reads, 2)
        try await model.disconnectBeforeUpdate(status: { _ in idle }, stop: { _, _ in XCTFail(); return idle })
        XCTAssertEqual(model.phase, .idle)
    }

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

    func testLateMeasurementCannotOverwriteReconnectedSession() async throws {
        let controls = DesktopCoreControls()
        let first = SessionControlTarget(sessionID: UUID(), revision: 3)
        let replacement = SessionControlTarget(sessionID: UUID(), revision: 3)
        let snapshot = SessionControlSnapshot(token: UUID(), mode: .rule, groups: [
            SessionNodeList(group: .chain, selected: "A", preferred: nil, automatic: false, members: ["A", "B"])
        ])
        controls.bind(first)
        await controls.inspect { SessionControlReply($0, state: snapshot) }
        var deliverLate: (() -> Void)?
        let started = expectation(description: "First session is waiting for the delay response")
        let measurement = Task {
            await controls.measure(.chain, members: ["A", "B"]) { request in
                XCTAssertEqual(request.target, first)
                guard request.member == "A" else {
                    XCTFail("The old batch requested its second member")
                    return SessionControlReply(request, delay: .unavailable)
                }
                return await withCheckedContinuation { continuation in
                    deliverLate = { continuation.resume(returning: SessionControlReply(request, delay: .measured(milliseconds: 900))) }
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(controls.measuring)
        controls.bind(nil)
        controls.bind(replacement)
        await controls.inspect { SessionControlReply($0, state: snapshot) }
        await controls.measure(.chain, members: ["A"]) { request in
            XCTAssertEqual(request.target, replacement)
            return SessionControlReply(request, delay: .measured(milliseconds: 12))
        }
        try XCTUnwrap(deliverLate)()
        await measurement.value
        XCTAssertEqual(controls.target, replacement)
        XCTAssertEqual(controls.latency[.chain], ["A": .measured(milliseconds: 12)])
        XCTAssertFalse(controls.measuring)
        XCTAssertNil(controls.error)
    }

    func testSuccessfulNodeReadClearsOnlyTheReadFailure() async {
        let controls = DesktopCoreControls()
        let target = SessionControlTarget(sessionID: id, revision: 1)
        let group = SessionNodeList(group: .access, selected: "A", preferred: nil, automatic: true, members: ["A", "B"])
        let snapshot = SessionControlSnapshot(token: token, mode: .rule, groups: [group])
        controls.bind(target)
        await controls.inspect { SessionControlReply($0, state: snapshot) }

        let select = SessionControlRequest(target, .select, token: token, group: .access, member: "B")
        let changed = await controls.change(select) { request in
            if request.action == .select { throw ServiceClientError.rejected("无法选择 B") }
            throw ServiceClientError.timeout
        }
        XCTAssertFalse(changed)
        XCTAssertNil(controls.state)
        XCTAssertNotNil(controls.readError)
        let selectionFailure = controls.selectionError
        XCTAssertNotNil(selectionFailure)
        await controls.inspect { SessionControlReply($0, state: snapshot) }
        XCTAssertEqual(controls.state, snapshot)
        XCTAssertNil(controls.readError)
        XCTAssertEqual(controls.selectionError, selectionFailure)

        await controls.measure(.access, members: ["B"]) { request in
            XCTAssertEqual(request.member, "B")
            throw ServiceClientError.timeout
        }
        let measurementFailure = controls.measurementError
        XCTAssertNotNil(measurementFailure)
        await controls.inspect { SessionControlReply($0, state: snapshot) }
        XCTAssertEqual(controls.measurementError, measurementFailure)
        await controls.measure(.access, members: ["B"]) { request in
            XCTAssertEqual(request.member, "B")
            return SessionControlReply(request, delay: .measured(milliseconds: 15))
        }
        XCTAssertNil(controls.measurementError)
        XCTAssertEqual(controls.selectionError, selectionFailure)
        XCTAssertEqual(controls.latency[.access], ["B": .measured(milliseconds: 15)])
        XCTAssertNil(controls.measuringMember)
        controls.bind(nil)
        XCTAssertNil(controls.error)
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
