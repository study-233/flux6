import XCTest
@testable import FreeV6Desktop

final class DesktopUpdaterTests: XCTestCase {
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
