import XCTest
import FreeV6UpdateSupport
@testable import FreeV6Desktop

final class DesktopUpdaterTests: XCTestCase {
    @MainActor func testInstallApprovalNeedsAnAcknowledgementBeforeTermination() async throws {
        let body: [String: Any] = ["format": 1, "build": 2, "minimumSourceBuild": 1, "maximumSourceBuild": 1,
                                   "architecture": UpdateRelease.architecture, "workerProtocol": 1, "serviceProtocol": 6,
                                   "settingsSchema": 1, "runtimeCatalogSHA256": String(repeating: "a", count: 64),
                                   "serviceSHA256": String(repeating: "b", count: 64)]
        let release = try UpdateRelease.decode(JSONSerialization.data(withJSONObject: body), currentBuild: 1)
        for next in [nil, UpdateEvent.Kind.finished, .installing] {
            let updater = DesktopUpdater()
            let operation = UUID()
            let events = AsyncThrowingStream<UpdateEvent, Error> { stream in
                stream.yield(UpdateEvent(.ready, operation: operation, release: release))
                if let next { stream.yield(UpdateEvent(next, operation: operation, release: release)) }
                stream.finish()
            }
            var replies: [Bool] = []
            var terminations = 0
            do {
                try await updater.follow(events, currentBuild: 1, answer: {
                    XCTAssertFalse(updater.installationAuthorized)
                    replies.append($0.install)
                }, prepare: { _, _ in }, install: {
                    XCTAssertTrue(updater.installationAuthorized)
                    terminations += 1
                })
                XCTAssertEqual(next, .installing)
            } catch {
                XCTAssertNotEqual(next, .installing)
                XCTAssertEqual(error as? UpdateFailure, .transport)
            }
            XCTAssertEqual(replies, [true])
            XCTAssertEqual(terminations, next == .installing ? 1 : 0)
            XCTAssertEqual(updater.installationAuthorized, next == .installing)
        }
    }

    @MainActor func testUnconfiguredChannelExitsWithoutPreparingNetworkOrInstalling() async {
        let updater = DesktopUpdater()
        updater.check(prepare: { _, _ in XCTFail("Unconfigured builds cannot prepare installation") },
                      install: { XCTFail("Unconfigured builds cannot install") })
        await updater.cancelForQuit()
        XCTAssertFalse(updater.busy)
        XCTAssertNotNil(updater.error)
        XCTAssertFalse(updater.installationAuthorized)
    }

    func testInstallationPreparationBlocksChangesButKeepsDiagnosticCommands() {
        var state = DesktopCommandState()
        XCTAssertTrue(state.availability(.checkUpdates).enabled)
        state.updateBusy = true
        XCTAssertFalse(state.availability(.checkUpdates).enabled)
        state.updatePreparing = true
        for command: DesktopCommand in [.connect, .quit, .importChain, .saveConfiguration, .configureService, .refreshService] {
            XCTAssertFalse(state.availability(command).enabled)
        }
        XCTAssertTrue(state.availability(.exportDiagnostics).enabled)
        XCTAssertTrue(state.availability(.showPage(.overview)).enabled)
    }
}
