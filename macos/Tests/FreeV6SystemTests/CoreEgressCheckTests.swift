import Foundation
import XCTest
@testable import FreeV6System

final class CoreEgressCheckTests: XCTestCase {
    private enum Failure: Error { case identity, route }
    private func response(_ code: Int32 = 0, _ text: String = "204 198.18.0.5") -> CommandResult {
        CommandResult(exit: .exited(code), output: Data(text.utf8))
    }

    func testProviderStartupFailuresCanBecomeUsable() throws {
        var time = 0.0, attempts = 0, validations = 0, routed = false
        let codes: [Int32] = [6, 7, 28, 35, 52, 55, 56, 0]
        try CoreEgressCheck.waitUntilUsable(now: { time }, sleep: { time += $0 },
            validateIdentity: { validations += 1 }, request: { limit in
                XCTAssertLessThanOrEqual(limit, 8)
                defer { attempts += 1 }
                return self.response(codes[attempts])
            }, validatePeer: { ip, ipv4 in
                XCTAssertEqual(ip, "198.18.0.5"); XCTAssertTrue(ipv4); routed = true
            })
        XCTAssertEqual(attempts, codes.count)
        XCTAssertEqual(validations, attempts * 2 + 1)
        XCTAssertTrue(routed)
    }

    func testPersistentFailureHasOneBoundedBudget() {
        var time = 0.0, attempts = 0
        XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(timeout: 1, now: { time }, sleep: { time += $0 },
            validateIdentity: {}, request: { limit in
                attempts += 1; XCTAssertLessThanOrEqual(limit, 1 - time)
                time += min(0.4, limit)
                return self.response(35)
            }, validatePeer: { _, _ in XCTFail("Failed transport cannot validate a route") })) {
                XCTAssertEqual($0 as? CoreEgressError, .timedOut(lastExit: 35))
            }
        XCTAssertEqual(time, 1); XCTAssertEqual(attempts, 2)
    }

    func testCertificateAndOtherTerminalFailuresAreNotRetried() {
        for code: Int32 in [1, 23, 60, 77] {
            var attempts = 0
            XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(sleep: { _ in XCTFail("No retry") },
                validateIdentity: {}, request: { _ in attempts += 1; return self.response(code) },
                validatePeer: { _, _ in XCTFail("No route check") })) {
                    XCTAssertEqual($0 as? CoreEgressError, .requestFailed(code))
                }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testOnly204WithLiteralPeerAddressIsAccepted() {
        for output in ["200 198.18.0.5", "302 198.18.0.5", "204", "204 example.test", "204 1.2.3.4 extra", "204 1.2.3.4\n"] {
            XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(sleep: { _ in XCTFail("No retry") },
                validateIdentity: {}, request: { _ in self.response(0, output) },
                validatePeer: { _, _ in XCTFail("Invalid peer") })) {
                    XCTAssertEqual($0 as? CoreEgressError, .invalidResponse)
                }
        }
    }

    func testIPv6PeerReachesRouteValidation() throws {
        var routed = false
        try CoreEgressCheck.waitUntilUsable(validateIdentity: {}, request: { _ in self.response(0, "204 2001:db8::1") },
            validatePeer: { ip, ipv4 in
                XCTAssertEqual(ip, "2001:db8::1"); XCTAssertFalse(ipv4); routed = true
            })
        XCTAssertTrue(routed)
    }

    func testWrongRouteFailsWithoutRetry() {
        XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(sleep: { _ in XCTFail("No retry") },
            validateIdentity: {}, request: { _ in self.response() },
            validatePeer: { _, _ in throw Failure.route })) { XCTAssertTrue($0 is Failure) }
    }

    func testCoreOrTunnelLossIsTerminalBeforeDuringAndAfterRequest() {
        for failureAt in 1...3 {
            var checks = 0, attempts = 0
            XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(sleep: { _ in XCTFail("No retry") },
                validateIdentity: { checks += 1; if checks == failureAt { throw Failure.identity } },
                request: { _ in attempts += 1; return self.response() }, validatePeer: { _, _ in })) {
                    XCTAssertTrue($0 is Failure)
                }
            XCTAssertEqual(checks, failureAt)
            XCTAssertEqual(attempts, failureAt == 1 ? 0 : 1)
        }
    }

    func testCoreLossBetweenRetriesPreventsAnotherRequest() {
        var time = 0.0, attempts = 0, alive = true
        XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(now: { time }, sleep: { time += $0; alive = false },
            validateIdentity: { if !alive { throw Failure.identity } },
            request: { _ in attempts += 1; return self.response(35) }, validatePeer: { _, _ in XCTFail("Not ready") })) {
                XCTAssertTrue($0 is Failure)
            }
        XCTAssertEqual(attempts, 1)
    }

    func testLateSuccessDoesNotExtendDeadline() {
        var time = 0.0
        XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(timeout: 1, now: { time },
            validateIdentity: {}, request: { _ in time = 1.1; return self.response() },
            validatePeer: { _, _ in XCTFail("Past deadline") })) {
                XCTAssertEqual($0 as? CoreEgressError, .timedOut(lastExit: nil))
            }
    }

    func testInvalidBudgetNeverRunsRequest() {
        for timeout in [0.0, -1, .nan, .infinity, 61] {
            XCTAssertThrowsError(try CoreEgressCheck.waitUntilUsable(timeout: timeout,
                validateIdentity: { XCTFail("Invalid budget") }, request: { _ in XCTFail("Invalid budget"); return self.response() },
                validatePeer: { _, _ in XCTFail("Invalid budget") }))
        }
    }
}
