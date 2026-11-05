import XCTest
@testable import FreeV6Desktop

final class DesktopCommandsTests: XCTestCase {
    func testConfigurationHandoffBlocksConflictingCommandsButKeepsNavigation() {
        var state = DesktopCommandState()
        state.service = .ready; state.settingsLoaded = true; state.settingsChanged = true
        state.configurationReady = true; state.configurationBusy = true
        for command: DesktopCommand in [.prepareConfiguration, .configureService, .refreshService, .checkCore,
                                         .downloadCore, .saveConfiguration, .reloadConfiguration, .quit] {
            XCTAssertFalse(state.availability(command, in: .main(.configuration)).enabled)
        }
        for command: DesktopCommand in [.showMain, .showPage(.overview), .help] {
            XCTAssertTrue(state.availability(command).enabled)
        }
        state.configurationBusy = false
        XCTAssertTrue(state.availability(.prepareConfiguration).enabled)
    }
    func testServiceHandshakeAndCoreCacheNeverEnableNetworkCommands() {
        var state = DesktopCommandState()
        for service in [DesktopServiceState.checking, .missing, .ready, .managing, .needsRepair] {
            state.service = service
            for coreAvailable in [false, true] {
                state.coreAvailable = coreAvailable
                XCTAssertFalse(state.availability(.connect).enabled)
                XCTAssertFalse(service.title.contains("已连接"))
            }
        }
        state.service = .missing
        XCTAssertEqual(state.primaryCommand, .configureService)
        state.service = .ready; state.coreAvailable = false
        XCTAssertEqual(state.primaryCommand, .refreshService)
        state.network = .idle
        XCTAssertEqual(state.primaryCommand, .showCore)
        state.coreAvailable = true
        XCTAssertEqual(state.primaryCommand, .reviewSetup)
        XCTAssertFalse(state.availability(.connect).enabled)
        state.configurationReady = true
        XCTAssertEqual(state.primaryCommand, .connect)
        XCTAssertTrue(state.availability(.connect).enabled)
    }

    func testRunningAndRecoveryKeepTheirCommandsWhenStartInputsDisappear() {
        var state = DesktopCommandState()
        state.service = .ready
        state.canTargetSession = true
        state.network = .running
        XCTAssertEqual(state.primaryCommand, .disconnect)
        XCTAssertTrue(state.availability(.disconnect).enabled)
        XCTAssertFalse(state.availability(.configureService).enabled)
        state.network = .recovering
        XCTAssertEqual(state.primaryCommand, .retryRecovery)
        XCTAssertTrue(state.availability(.retryRecovery).enabled)
        state.canTargetSession = false
        XCTAssertEqual(state.primaryCommand, .refreshService)
        for phase in [DesktopNetworkPhase.occupied, .unknown, .connecting, .disconnecting] {
            state.network = phase
            XCTAssertFalse(state.availability(.disconnect).enabled)
            XCTAssertFalse(state.availability(.connect).enabled)
        }
    }

    func testConfigurationCommandsFollowFocusedSceneAndRealWriteState() {
        var state = DesktopCommandState()
        state.settingsLoaded = true; state.settingsChanged = true
        for context in [CommandContext.application, .main(.overview), .main(.nodes), .main(.logs),
                        .preferences(.general), .preferences(.account), .preferences(.core), .preferences(.service)] {
            XCTAssertFalse(state.availability(.saveConfiguration, in: context).enabled)
            XCTAssertFalse(state.availability(.reloadConfiguration, in: context).enabled)
        }
        for context in [CommandContext.main(.configuration), .preferences(.rules)] {
            XCTAssertTrue(state.availability(.saveConfiguration, in: context).enabled)
            state.settingsBusy = true
            XCTAssertFalse(state.availability(.saveConfiguration, in: context).enabled)
            XCTAssertFalse(state.availability(.reloadConfiguration, in: context).enabled)
            state.settingsBusy = false; state.settingsChanged = false
            XCTAssertFalse(state.availability(.saveConfiguration, in: context).enabled)
            XCTAssertTrue(state.availability(.reloadConfiguration, in: context).enabled)
            state.settingsChanged = true
        }
    }

    func testInFlightPreparationAllowsCancellationButRejectsDuplicateWork() {
        var state = DesktopCommandState()
        state.service = .ready; state.coreBusy = true; state.coreCancelable = true
        XCTAssertFalse(state.availability(.downloadCore).enabled)
        XCTAssertFalse(state.availability(.checkCore).enabled)
        XCTAssertTrue(state.availability(.cancelCoreDownload).enabled)
        XCTAssertTrue(state.availability(.quit).enabled) // Quit cancels and waits for worker exit.
        state.settingsBusy = true
        XCTAssertFalse(state.availability(.quit).enabled)
        state.settingsBusy = false; state.service = .managing
        XCTAssertFalse(state.availability(.quit).enabled)
    }

    func testPromptAndTerminationRejectAllNewActions() {
        var state = DesktopCommandState()
        state.service = .ready
        let commands: [DesktopCommand] = [.downloadCore, .checkCore, .refreshService, .configureService,
                                         .showMain, .showPage(.configuration), .quit]
        state.promptActive = true
        for command in commands { XCTAssertFalse(state.availability(command).enabled) }
        state.promptActive = false; state.terminating = true
        for command in commands { XCTAssertFalse(state.availability(command).enabled) }
    }

    func testQuitCannotDiscardPendingCredentialOrInterruptAuthorization() {
        var state = DesktopCommandState()
        state.service = .ready
        state.credentialsBusy = true
        XCTAssertFalse(state.availability(.quit).enabled)
        state.credentialsBusy = false; state.credentialsPending = true
        XCTAssertFalse(state.availability(.quit).enabled)
        XCTAssertTrue(state.availability(.showMain).enabled)
        state.credentialsPending = false
        XCTAssertTrue(state.availability(.quit).enabled)
    }

    func testPreparationRequiresReadyInputsAndNeverEnablesConnection() {
        var state = DesktopCommandState()
        XCTAssertFalse(state.availability(.prepareConfiguration).enabled)
        state.configurationReady = true
        XCTAssertTrue(state.availability(.prepareConfiguration).enabled)
        state.credentialsBusy = true
        XCTAssertFalse(state.availability(.prepareConfiguration).enabled)
        state.credentialsBusy = false; state.credentialsPending = true
        XCTAssertFalse(state.availability(.prepareConfiguration).enabled)
        state.credentialsPending = false; state.settingsBusy = true
        XCTAssertFalse(state.availability(.prepareConfiguration).enabled)
        state.settingsBusy = false
        XCTAssertFalse(state.availability(.connect).enabled)
    }
}
