import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import FreeV6Desktop
import FreeV6System
import FreeV6Business
import FreeV6UpdateSupport

typealias Page = DesktopPage

#if FREEV6_UI_FIXTURE
let interfaceFixture = true
#else
let interfaceFixture = false
#endif

@MainActor final class WindowNavigation: ObservableObject {
    @Published fileprivate(set) var page: Page = .overview
    func show(_ destination: Page) {
        if destination != page { page = destination }
    }
}

@MainActor final class AppModel: ObservableObject {
    // Navigation isn't a network or data change. Notify only the window shell.
    let navigation = WindowNavigation()
    var page: Page? {
        get { navigation.page }
        set { navigation.show(newValue ?? .overview) }
    }
    @Published private(set) var dashboard: DashboardLayout
    @Published var dashboardDraft: DashboardLayout?
    var displayedDashboard: DashboardLayout { dashboardDraft ?? dashboard }

    var dashboardHasChanges: Bool { dashboardDraft.map { $0 != dashboard } ?? false }

    func saveDashboard() {
        guard let draft = dashboardDraft, let data = try? draft.encoded() else { return }
        defaults.set(data, forKey: "dashboardLayout")
        dashboard = draft
        dashboardDraft = nil
    }
    @Published var setupDetail: SetupDetail?
    @Published var error: String?
    @Published private(set) var serviceActionError: String?
    @Published var serviceStatus = "正在检查网络服务…"
    @Published var serviceState = DesktopServiceState.checking
    @Published var serviceBusy = false
    @Published var serviceInstalled = false
    @Published private(set) var promptActive = false
    @Published private(set) var terminating = false
    @Published private var checkingConfiguration = false
    var configurationBusy: Bool { checkingConfiguration || network.phase.busy }
    typealias SendControl = (SessionControlRequest, CodeIdentity?) async throws -> SessionControlReply
    private let sendControl: SendControl
    #if FREEV6_UI_FIXTURE
    var failNextDefaultSave = false
    var handleFixtureCommand: ((DesktopCommand) -> Bool)?
    #endif
    let network = DesktopNetworkSession()
    let startup: DesktopStartup
    var onShowWindow: (() -> Void)?
    let controls: DesktopCoreControls
    let logs: DesktopLogs
    let updater = DesktopUpdater()
    @Published var updateRecoveryMessage: String?
    @Published var updateRecoveryBlocksConnection = true
    @Published var nodeGroup = SessionNodeGroup.access
    private var pendingNodeRestoreTarget: SessionControlTarget?
    #if FREEV6_UI_FIXTURE
    var fixtureAccessNodeNames: [String]?
    #endif
    @Published private(set) var modeSaveError: String?
    @Published private(set) var pendingWorkingMode: CoreMode?
    @Published private(set) var failedWorkingMode: CoreMode?
    private weak var trackedStatusMenu: NSMenu?
    @Published private(set) var trafficReport: TrafficReport?
    @Published private(set) var accountingError: String?
    private var lastObservation: TimeInterval = 0
    private var collectingTraffic = false
    private var trafficClock: Task<Void, Never>?
    private var serviceIdentity: CodeIdentity?
    private var heartbeat: Task<Void, Never>?
    private var businessStarted = false
    var connectionTitle: String {
        serviceState == .ready || network.mayOwnSession ? network.phase.title : serviceState.title
    }
    var connectionSymbol: String {
        serviceState == .ready || network.mayOwnSession ? network.phase.symbol : serviceState.symbol
    }
    var canManageService: Bool {
        !interfaceFixture && !serviceBusy && !warp.busy && !configurationBusy && !network.mayOwnSession &&
            (serviceState != .ready || network.phase == .idle)
    }
    @Published private(set) var configurationSummary: ConfigurationSummary?
    @Published private(set) var configurationError: String?
    @Published private(set) var configurationCheckedByService = false
    let business: BusinessModel
    let core: RuntimeModel
    let geodata: GeodataModel
    let warp: WarpModel
    let session: BusinessSession
    private let defaults: UserDefaults
    private var observations: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard, workerLocation: WorkerLocation? = nil,
         sendControl: @escaping SendControl = AppModel.liveControl) {
        self.sendControl = sendControl
        self.defaults = defaults
        let notices = Bundle.main.resourceURL.flatMap { try? StartupNotices(directory: $0.appendingPathComponent("Notices")) }
        startup = DesktopStartup(defaults: defaults, notices: notices)
        self.logs = DesktopLogs(directory: workerLocation?.logs ?? (try? WorkerLocation.application().logs))
        controls = DesktopCoreControls(defaults: defaults)
        dashboard = DashboardLayout(data: defaults.data(forKey: "dashboardLayout"))
        session = BusinessSession(location: workerLocation)
        business = BusinessModel(session: session)
        core = RuntimeModel(session: session)
        geodata = GeodataModel(session: session)
        warp = WarpModel(session: session)
        self.logs.record(.opened)
        observations.formUnion(observeLogEvents())
        startup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.logs.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        // Commands depend on nested models, including text edits and progress.
        business.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        core.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        geodata.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        warp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        // Traffic has its own observers in the speed chart and menu. Publishing every
        // sample here also invalidates the toolbar, node list and configuration form.
        func forward<P: Publisher>(_ publisher: P) where P.Failure == Never, P.Output: Equatable {
            publisher.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &observations)
        }
        forward(controls.$nodeCatalogRevision)
        forward(controls.$state)
        forward(controls.$inspecting)
        forward(controls.$writing)
        forward(controls.$measuring)
        forward(controls.$measuringMember)
        forward(controls.$latency)
        forward(controls.$readError)
        forward(controls.$modeError)
        forward(controls.$selectionError)
        forward(controls.$measurementError)
        network.$phase.removeDuplicates().sink { [weak self] phase in
            self?.failedWorkingMode = nil
            self?.modeSaveError = nil
            if phase != .running { self?.controls.bind(nil) }
        }.store(in: &observations)
    }

    func startMonitoring() {
        guard heartbeat == nil else { return }
        let notifications = NotificationCenter.default
        notifications.publisher(for: NSMenu.didBeginTrackingNotification).sink { [weak self] notice in
            guard let self, let menu = notice.object as? NSMenu,
                  menu.item(withTitle: DesktopCommand.showMain.title) != nil,
                  menu.item(withTitle: DesktopCommand.quit.title) != nil else { return }
            trackedStatusMenu = menu
            Task { await self.updateTraffic() }
        }.store(in: &observations)
        notifications.publisher(for: NSMenu.didEndTrackingNotification).sink { [weak self] notice in
            guard let self, let menu = notice.object as? NSMenu, menu === trackedStatusMenu else { return }
            trackedStatusMenu = nil
            if !trafficVisible { controls.hideTraffic() }
        }.store(in: &observations)
        trafficClock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                await self?.updateTraffic()
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await self?.refreshNetwork()
            }
        }
        if startup.accepted { startBusiness() }
        else { Task { await refreshService() } }
    }

    func acceptNotices() {
        startup.acceptNotices()
        if startup.accepted { startBusiness() }
    }

    private func startBusiness() {
        guard !businessStarted else { return }
        businessStarted = true
        Task { await loadTrafficReport() }
        Task {
            async let settings: Void = business.reload()
            async let runtime: Void = core.refresh()
            async let data: Void = geodata.refresh()
            async let service: Void = refreshService()
            async let notice: Void = business.refreshNotice()
            _ = await (settings, runtime, data, service, notice)
            await startAutomaticConnection()
        }
    }

    private func startAutomaticConnection() async {
        if network.phase == .running { startup.cancelAutomatic(); return }
        await startup.runAutomatic(prerequisite: {
            if updateRecoveryMessage != nil || updateRecoveryBlocksConnection || updater.busy {
                return "本次启动涉及应用升级，请确认网络服务后手动连接。"
            }
            guard !terminating, serviceState == .ready, network.phase == .idle else {
                return "自动连接已跳过：" + connectionTitle
            }
            return nil
        }, waitForNetwork: { await startup.waitForNetwork() }, inspect: {
            if business.snapshot?.cloud?.enabled == true {
                if !business.cloudOpen { await business.refreshNotice() }
            } else { try await warp.inspectForStartup() }
        }, connect: { attempt in
            if let reason = configurationPrerequisite { return reason }
            await connect(automaticAttempt: attempt)
            return network.phase == .running ? nil : (network.error ?? "自动连接未完成，请检查连接条件。")
        })
    }

    deinit { heartbeat?.cancel(); trafficClock?.cancel() }

    var commandState: DesktopCommandState {
        var state = DesktopCommandState()
        state.noticesAccepted = startup.accepted
        state.service = serviceState
        state.network = network.phase
        state.canMeasureNodes = !controls.measuring && availableGroup?.members.isEmpty == false
        state.canTargetSession = network.canTargetSession
        state.coreBusy = core.busy || configurationBusy
        state.coreAvailable = interfaceFixture || core.package?.available == true
        state.coreCancelable = core.canCancel
        state.settingsBusy = business.busy || configurationBusy
        state.settingsLoaded = business.snapshot != nil
        state.cloudRefreshAvailable = business.canRefreshCloud
        state.cloudEnabled = business.snapshot?.cloud?.enabled == true
        state.settingsChanged = business.hasChanges
        state.promptActive = promptActive
        state.terminating = terminating
        state.hasVisibleLogs = !logs.visible.isEmpty
        state.updateBusy = updater.busy
        state.updatePreparing = updater.preparingInstallation
        state.credentialsBusy = warp.busy || configurationBusy
        state.credentialsPending = warp.hasPending
        state.configurationReady = configurationPrerequisite == nil
        state.configurationBusy = configurationBusy
        return state
    }

    var configurationPrerequisite: String? {
        if !startup.accepted { return "请先在主窗口阅读并同意用户协议与隐私政策。" }
        if updateRecoveryBlocksConnection { return updateRecoveryMessage ?? "正在确认本机升级记录。" }
        if configurationBusy || warp.busy || business.busy || serviceBusy || core.busy || geodata.busy { return "请等待当前操作结束。" }
        if serviceState == .ready && network.phase != .idle { return "请先确认网络会话已停止。" }
        if business.snapshot == nil { return "请先载入代理规则。" }
        if business.hasChanges { return "请先保存代理规则，再检查连接配置。" }
        if interfaceFixture && serviceState == .ready { return nil }
        if business.snapshot?.cloud?.enabled == true {
            if !business.cloudOpen { return "备用配置当前未开放，请刷新公告或停用备用配置。" }
        } else if warp.hasPending || warp.summary == nil { return "请先检查或注册已保存的 WARP 凭据。" }
        if core.package?.available != true { return "请先准备网络核心。" }
        if geodata.package?.available != true { return "请先准备规则数据。" }
        return nil
    }

    func prepareConfiguration() async {
        guard !terminating, configurationPrerequisite == nil, let settings = business.snapshot,
              let runtime = core.package, let data = geodata.package else { return }
        checkingConfiguration = true; configurationError = nil; configurationSummary = nil; configurationCheckedByService = false
        let identity = serviceIdentity
        defer { checkingConfiguration = false }
        do {
            let cache = try WorkerLocation.application().cache
            let summary = try await withPreparedConfiguration(settings: settings, runtimeId: runtime.resourceId,
                                                                   geodataId: data.resourceId) { prepared in
                if let identity {
                    try await Task.detached {
                        let request = try Self.transfer(prepared, cache: cache, identity: identity)
                        _ = try ServiceClient.checkConfiguration(request, identity: identity)
                    }.value
                }
                return ConfigurationSummary(prepared)
            }
            guard business.snapshot?.revision == settings.revision, !business.hasChanges else { throw WorkerClientError.staleConfiguration }
            configurationSummary = summary
            configurationCheckedByService = identity != nil
        } catch { configurationError = error.localizedDescription }
    }

    var activeCredentialRevision: UUID? {
        if let cloud = business.snapshot?.cloud, cloud.enabled { return cloud.id }
        return warp.summary?.revision
    }

    private func withPreparedConfiguration<T: Sendable>(settings: SettingsSnapshot, runtimeId: String, geodataId: String, interactionAllowed: Bool = true,
        perform: @escaping @Sendable (PreparedConfiguration) async throws -> T) async throws -> T {
        guard settings.cloud?.enabled == true else {
            return try await warp.withPreparedConfiguration(settings: settings, runtimeId: runtimeId, geodataId: geodataId,
                                                             interactionAllowed: interactionAllowed, perform: perform)
        }
        let client = try session.worker()
        let key = try await ChainProfileKey(storage: KeychainSecretStorage.cloudKey()).load(allowCreation: false, interactionAllowed: interactionAllowed)
        let prepared = try await client.prepareCloud(settings: settings, key: key, runtimeId: runtimeId, geodataId: geodataId)
        return try await perform(prepared)
    }

    private nonisolated static func transfer(_ prepared: PreparedConfiguration, cache: URL,
                                             identity: CodeIdentity) throws -> ConfigurationCheckRequest {
        try ServiceResourceTransfer.prepare(cache: cache, runtimeID: prepared.runtimeId, geodataID: prepared.geodataId,
                                            identity: identity)
        return ConfigurationCheckRequest(runtimeID: prepared.runtimeId, geodataID: prepared.geodataId,
            settingsRevision: prepared.settingsRevision, credentialRevision: prepared.credentialRevision,
            configuration: prepared.configuration)
    }

    var availableGroup: SessionNodeList? {
        guard let groups = controls.state?.groups else { return nil }
        return groups.first(where: { $0.group == nodeGroup }) ?? groups.first
    }

    var browsingOfflineNodes: Bool {
        workingModeSource == .savedDefault
    }

    var nodeOptions: [DesktopNodeGroup] {
        if network.phase == .running { return (controls.state?.groups ?? []).map(DesktopNodeGroup.init(session:)) }
        guard browsingOfflineNodes else { return [] }
        guard let snapshot = business.snapshot else { return controls.previousGroups }
        if let cloud = snapshot.cloud, cloud.enabled {
            return [controls.offlineGroup(.access, names: cloud.names, source: .configuration)]
        }
        #if FREEV6_UI_FIXTURE
        let warp = fixtureAccessNodeNames ?? DesktopNodeGroup.warpNames
        #else
        let warp = DesktopNodeGroup.warpNames
        #endif
        var groups = [controls.offlineGroup(.access, names: warp, source: .configuration)]
        if let chain = snapshot.chain, chain.enabled {
            groups.append(controls.offlineGroup(.chain, names: chain.names, source: .configuration))
        }
        return groups
    }

    var displayedNodeGroup: DesktopNodeGroup? {
        let groups = nodeOptions
        return groups.first { $0.group == nodeGroup } ?? groups.first
    }

    @discardableResult func chooseNode(_ member: String?, in group: SessionNodeGroup,
                                       expecting target: SessionControlTarget?) async -> Bool {
        guard startup.accepted, !terminating, !promptActive, !updater.preparingInstallation, !controls.writing,
              target == network.runningTarget, let options = nodeOptions.first(where: { $0.group == group }),
              member.map(options.members.contains) ?? (options.automatic || options.source != .session) else { return false }
        if let target, let state = controls.state {
            guard serviceState == .ready else { return false }
            if let member { return await selectMember(member, group: group, target: target, token: state.token) }
            return await useAutomaticSelection(target: target, token: state.token)
        }
        guard browsingOfflineNodes else { return false }
        controls.saveNode(member, in: group)
        return true
    }

    private var trafficVisible: Bool {
        if trackedStatusMenu != nil { return true }
        guard NSApp.isActive, page == .overview, displayedDashboard.contains(.speed) else { return false }
        return NSApp.windows.contains { $0.identifier?.rawValue == "freev6-main" && $0.occlusionState.contains(.visible) }
    }

    private func acceptTrafficReport(_ report: TrafficReport) {
        if let previous = trafficReport,
           previous.total.upload > report.total.upload || previous.total.download > report.total.download { return }
        accountingError = nil
        if trafficReport != report { trafficReport = report }
    }

    func loadTrafficReport() async {
        do { acceptTrafficReport(try await session.worker().trafficReport()) }
        catch { accountingError = error.localizedDescription }
    }

    private func account(_ sample: CoreTrafficSample, for id: UUID) async {
        do {
            acceptTrafficReport(try await session.worker().observeTraffic(sessionID: id, upload: sample.upTotal,
                                                                           download: sample.downTotal))
        } catch { accountingError = error.localizedDescription }
    }

    private func updateTraffic() async {
        guard !terminating, !collectingTraffic, let target = network.runningTarget, controls.target == target else { return }
        let visible = trafficVisible
        let now = ProcessInfo.processInfo.systemUptime
        if !visible {
            controls.hideTraffic()
            guard now - lastObservation >= 20 else { return }
        }
        collectingTraffic = true
        defer { collectingTraffic = false }
        let sample: CoreTrafficSample?
        if visible {
            sample = await controls.sample(using: exchange)
            if !trafficVisible { controls.hideTraffic() }
        } else {
            do { sample = try await exchange(SessionControlRequest(target, .traffic)).traffic }
            catch { accountingError = error.localizedDescription; return }
        }
        if let sample, now - lastObservation >= 5 {
            lastObservation = now
            await account(sample, for: target.sessionID)
        }
    }

    private func exchange(_ query: SessionControlRequest) async throws -> SessionControlReply {
        guard !terminating, network.runningTarget == query.target else {
            throw ServiceClientError.rejected("此会话已经变化，请重新查看连接状态。")
        }
        return try await sendControl(query, serviceIdentity)
    }

    private nonisolated static func liveControl(_ query: SessionControlRequest, identity: CodeIdentity?) async throws -> SessionControlReply {
        guard let identity else { throw ServiceClientError.rejected("请重新检查网络服务。") }
        return try await Task.detached { try ServiceClient.control(query, identity: identity) }.value
    }

    func refreshCoreControls(restoreChoices: Bool = false) async {
        let target = network.runningTarget
        controls.bind(target)
        if restoreChoices { pendingNodeRestoreTarget = target }
        guard let target else { pendingNodeRestoreTarget = nil; return }
        await controls.inspect(using: exchange)
        guard target == network.runningTarget, pendingNodeRestoreTarget == target,
              !controls.inspecting, !controls.writing, let state = controls.state else { return }
        pendingNodeRestoreTarget = nil
        for list in state.groups {
            guard target == network.runningTarget else { return }
            if let request = controls.restoration(for: list.group) {
                _ = await controls.change(request, using: exchange)
            }
        }
    }

    var workingModeSource: DashboardWorkingMode? {
        DashboardWorkingMode.source(phase: network.phase, service: serviceState, mayOwnSession: network.mayOwnSession)
    }

    var workingMode: CoreMode? {
        switch workingModeSource {
        case .savedDefault: return business.snapshot.flatMap { CoreMode(rawValue: $0.settings.mode.rawValue) }
        case .liveSession: return controls.state?.mode
        case nil: return nil
        }
    }

    var canSelectWorkingMode: Bool {
        guard startup.accepted, !terminating, !promptActive, !updater.preparingInstallation,
              !serviceBusy, !configurationBusy, !controls.writing, !business.busy, business.snapshot != nil,
              pendingWorkingMode == nil, let source = workingModeSource else { return false }
        return source == .savedDefault || (network.runningTarget != nil && controls.state != nil)
    }

    func selectWorkingMode(_ mode: CoreMode) async {
        guard canSelectWorkingMode, let source = workingModeSource, let baseline = business.snapshot,
              let preference = ProxyMode(rawValue: mode.rawValue) else { return }
        // A retry can save the default without reissuing an already confirmed live change.
        guard workingMode != mode || failedWorkingMode == mode else { return }
        let target = network.runningTarget
        pendingWorkingMode = mode
        failedWorkingMode = nil
        modeSaveError = nil
        defer { pendingWorkingMode = nil }

        if source == .liveSession {
            guard let state = controls.state, let target else { return }
            if state.mode != mode {
                let request = SessionControlRequest(target, .setMode, token: state.token, mode: mode)
                guard await controls.change(request, using: exchange) else {
                    if network.runningTarget == target { failedWorkingMode = mode }
                    return
                }
            }
            guard network.runningTarget == target, controls.state?.mode == mode else { return }
        }

        do {
            #if FREEV6_UI_FIXTURE
            if failNextDefaultSave { failNextDefaultSave = false; throw WorkerClientError.staleConfiguration }
            #endif
            try await business.saveConfirmedMode(preference, baseline: baseline)
        } catch {
            let saved = try? await business.refreshModeBaseline()
            guard workingModeSource == source, network.runningTarget == target else { return }
            if saved == preference { return }
            failedWorkingMode = mode
            let next = saved.map { "下次连接使用" + $0.title } ?? "下次默认值未确认"
            modeSaveError = source == .liveSession
                ? "当前已切至" + mode.title + "；" + next + "。"
                : "默认模式未能保存，" + next + "。"
        }
    }

    @discardableResult func useAutomaticSelection(target: SessionControlTarget, token: UUID) async -> Bool {
        await controls.change(SessionControlRequest(target, .unpin, token: token), using: exchange)
    }

    @discardableResult func selectMember(_ name: String, group: SessionNodeGroup, target: SessionControlTarget, token: UUID) async -> Bool {
        let query = SessionControlRequest(target, .select, token: token, group: group, member: name)
        return await controls.change(query, using: exchange)
    }

    func measure(group: SessionNodeGroup, members: [String]) async {
        await controls.measure(group, members: members, using: exchange)
    }

    private func refreshNetwork() async {
        guard !terminating, !serviceBusy, !configurationBusy, let identity = serviceIdentity else { return }
        await network.refresh { id in
            try await Task.detached { try ServiceClient.sessionStatus(renewing: id, identity: identity) }.value
        }
        Task { await refreshCoreControls() }
    }

    private func connect(automaticAttempt: UUID? = nil) async {
        guard commandState.availability(.connect).enabled, let identity = serviceIdentity,
              let settings = business.snapshot, let runtime = core.package, let data = geodata.package else { return }
        await network.connect { token in
            try await CampusIPv6.check(developerMode: settings.settings.devMode)
            let cache = try WorkerLocation.application().cache
            let prepared = try await withPreparedConfiguration(settings: settings, runtimeId: runtime.resourceId,
                geodataId: data.resourceId, interactionAllowed: automaticAttempt == nil) { $0 }
            guard !business.hasChanges, business.snapshot?.revision == prepared.settingsRevision,
                  activeCredentialRevision == prepared.credentialRevision else { throw WorkerClientError.staleConfiguration }
            let request = try await Task.detached { try Self.transfer(prepared, cache: cache, identity: identity) }.value
            if settings.cloud?.enabled == true {
                let client = try session.worker()
                guard try await client.settings().revision == settings.revision,
                      try await client.maintainerNotice(refresh: false).cloudAllowed else { throw WorkerClientError.staleConfiguration }
            }
            if let automaticAttempt {
                guard startup.currentAttempt == automaticAttempt, !terminating, !updater.busy,
                      !updateRecoveryBlocksConnection else { throw CancellationError() }
            }
            return try await Task.detached { try ServiceClient.startSession(request, idleToken: token, identity: identity) }.value
        }
        if network.phase == .unknown { await refreshNetwork() }
        else { await refreshCoreControls(restoreChoices: true) }
    }

    func stop(_ id: UUID, revision: UInt64, identity: CodeIdentity) async throws -> NetworkSessionReply {
        let target = SessionControlTarget(sessionID: id, revision: revision)
        let sample = try? await Task.detached {
            try ServiceClient.control(SessionControlRequest(target, .traffic), identity: identity, timeout: 2).traffic
        }.value
        let stopped = try await Task.detached { try ServiceClient.stopSession(sessionID: id, revision: revision, identity: identity) }.value
        if let sample { await account(sample, for: id) }
        return stopped
    }

    private func disconnect() async {
        guard !terminating, let identity = serviceIdentity, network.phase == .running || network.phase == .recovering else { return }
        do {
            try await network.disconnect { id, revision in try await self.stop(id, revision: revision, identity: identity) }
        } catch { await refreshNetwork() }
    }

    func perform(_ command: DesktopCommand, in context: CommandContext, openWindow: OpenWindowAction) {
        // Revalidate at execution, even if a menu was opened before state changed.
        guard commandState.availability(command, in: context).enabled else { return }
        #if FREEV6_UI_FIXTURE
        if handleFixtureCommand?(command) == true { return }
        #endif
        switch command {
        case .showMain:
            openWindow(id: "main"); showWindow()
        case .showPage(let page):
            setupDetail = nil; self.page = page; openWindow(id: "main"); showWindow()
        case .configureService, .showCore, .reviewSetup:
            switch command {
            case .configureService: setupDetail = .service
            case .showCore: setupDetail = .core
            default: setupDetail = nextSetupDetail
            }
            page = .overview; openWindow(id: "main"); showWindow()
        case .refreshService: Task { await refreshService() }
        case .checkCore: Task { await core.refresh() }
        case .downloadCore: core.beginDownload()
        case .cancelCoreDownload: core.cancel()
        case .prepareConfiguration:
            setupDetail = .configuration
            page = .overview; openWindow(id: "main"); showWindow()
            Task { await prepareConfiguration() }
        case .saveConfiguration: Task { await business.save() }
        case .reloadConfiguration:
            if business.hasChanges {
                promptActive = true
                let alert = NSAlert()
                alert.messageText = "放弃未保存的更改并重新载入？"
                alert.informativeText = "当前代理规则草稿将被已保存的配置替换。"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "重新载入")
                let response = alert.runModal()
                promptActive = false
                guard response == .alertSecondButtonReturn else { return }
            }
            Task { await business.reload() }
        case .help:
            openWindow(id: "help"); NSApp.activate(ignoringOtherApps: true)
        case .quit: NSApp.terminate(nil)
        case .connect: startup.cancelAutomatic(); Task { await connect() }
        case .disconnect, .retryRecovery: startup.cancelAutomatic(); Task { await disconnect() }
        case .measureNodes:
            if let group = availableGroup { Task { await measure(group: group.group, members: group.members) } }
        case .importChain:
            if !context.editsConfiguration {
                page = .configuration
                openWindow(id: "main"); showWindow()
            }
            let sourceWindow = NSApp.keyWindow
            let panel = NSOpenPanel()
            panel.title = "导入链式代理配置"
            panel.prompt = "导入"
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.yaml, .json, .plainText]
            promptActive = true
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
                guard let self else { return }
                self.promptActive = false
                guard result == .OK, let url = panel.url,
                      self.commandState.availability(.importChain, in: context).enabled else { return }
                Task { await self.business.changeChain(.load(.file(url))) }
            }
            if let sourceWindow { panel.beginSheetModal(for: sourceWindow, completionHandler: finish) }
            else { panel.begin(completionHandler: finish) }
        case .refreshCloud:
            page = .configuration; openWindow(id: "main"); showWindow()
            Task { await business.changeCloud(.load(.refresh)) }
        case .exportLogs, .exportDiagnostics:
            let diagnostics = command == .exportDiagnostics
            let text = diagnostics ? diagnosticText() : DesktopLogs.text(logs.visible)
            let panel = NSSavePanel()
            panel.title = command.title
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = diagnostics ? "FreeV6-诊断.txt" : "FreeV6-日志.txt"
            panel.message = diagnostics ? "将保存版本、组件状态和最近事件。文件仅写入你选择的位置。" : "将保存当前级别和暂停状态下显示的事件。"
            promptActive = true
            panel.begin { [weak self] result in
                guard let self else { return }
                defer { self.promptActive = false }
                guard result == .OK, let destination = panel.url else { return }
                do { try Data(text.utf8).write(to: destination, options: .atomic) }
                catch {
                    let alert = NSAlert()
                    alert.messageText = "文件未能保存"
                    alert.informativeText = "请检查所选位置是否可以写入，再重新导出。"
                    alert.runModal()
                }
            }
        case .checkUpdates:
            startup.cancelAutomatic()
            page = .overview; openWindow(id: "main"); showWindow()
            updater.check(prepare: { [weak self] release, source in
                guard let self else { throw UpdateFailure.cancelled }
                try await self.prepareUpdate(release, sourceBuild: source)
            }, install: { NSApp.terminate(nil) })
        }
    }

    func refreshService() async {
        guard !serviceBusy, !configurationBusy, !terminating else { return }
        serviceBusy = true; serviceState = .checking; error = nil; configurationCheckedByService = false
        serviceStatus = "正在检查网络服务…"
        defer { serviceBusy = false }
        await readServiceStatus()
    }

    private func readServiceStatus() async {
        network.invalidate()
        do {
            let result = try await Task.detached { () throws -> (CodeIdentity, HandshakeReply)? in
                guard let identity = try InstalledServiceStatus.identity() else { return nil }
                return (identity, try ServiceClient.handshake(identity: identity))
            }.value
            serviceIdentity = result?.0
            serviceInstalled = result != nil
            if let (identity, reply) = result {
                serviceState = .ready
                serviceStatus = "网络服务已就绪 · \(reply.serviceVersion)"
                await network.refresh { id in
                    try await Task.detached { try ServiceClient.sessionStatus(renewing: id, identity: identity) }.value
                }
                Task { await refreshCoreControls() }
            } else {
                serviceState = .missing
                serviceStatus = "网络服务尚未安装"
            }
        } catch {
            serviceIdentity = nil
            serviceInstalled = true
            serviceState = .needsRepair
            serviceStatus = "网络服务需要修复"
            self.error = error.localizedDescription
        }
        await refreshUpdateRecovery()
    }

    func manageService(_ action: ServiceInstallationAction) async {
        #if FREEV6_UI_FIXTURE
        serviceActionError = "授权未完成。请再次点击安装网络服务。"
        #else
        guard canManageService, !terminating else { return }
        if action == .install && !startup.accepted { return }
        serviceBusy = true; serviceState = .managing; serviceActionError = nil; error = nil; configurationCheckedByService = false
        serviceStatus = "正在等待管理员授权…"
        defer { serviceBusy = false }
        do {
            let app = Bundle.main.bundleURL
            let identity = try CodeIdentity.protectedFile(at: app, identifier: "dev.freev6.desktop")
            let request = try ServiceInstallationRequest(action: action, app: app, uid: getuid(), clientHash: identity.cdHash)
            try await Task.detached { try request.execute() }.value
            await readServiceStatus()
        } catch {
            serviceActionError = error.localizedDescription
            await readServiceStatus()
            self.error = serviceActionError
        }
        #endif
    }

    func showWindow() {
        onShowWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "freev6-main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func beginTermination() -> NSApplication.TerminateReply {
        startup.cancelAutomatic()
        guard !terminating, !promptActive else { return .terminateCancel }
        if updater.installationAuthorized { return .terminateNow }
        let availability = commandState.availability(.quit)
        guard availability.enabled else {
            let alert = NSAlert()
            alert.messageText = "操作正在进行"
            alert.informativeText = availability.reason ?? "请等待当前操作结束。"
            alert.runModal()
            return .terminateCancel
        }
        var saveBeforeExit = false
        let drafts = [(business.hasChanges, "代理规则"), (business.hasPortalChanges, "校园登录地址"), (dashboardHasChanges, "仪表盘布局")]
            .compactMap { $0.0 ? $0.1 : nil }
        if !drafts.isEmpty {
            promptActive = true
            let alert = NSAlert()
            alert.messageText = "退出前保存" + drafts.joined(separator: "和") + "？"
            alert.informativeText = "只有已保存的更改会在下次打开时保留。"
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "返回编辑")
            alert.addButton(withTitle: "放弃并退出")
            let response = alert.runModal()
            promptActive = false
            if response == .alertSecondButtonReturn {
                page = (business.hasChanges || business.hasPortalChanges) ? .configuration : .overview
                showWindow()
                return .terminateCancel
            }
            saveBeforeExit = response == .alertFirstButtonReturn
        }
        terminating = true
        Task {
            if saveBeforeExit && business.hasChanges {
                await business.save()
                if business.error != nil || business.hasChanges {
                    terminating = false
                    page = .configuration; showWindow()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            if saveBeforeExit && business.hasPortalChanges, await business.savePortalAddress() != nil {
                terminating = false
                page = .configuration; showWindow()
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            do {
                if let identity = serviceIdentity {
                    try await network.disconnectBeforeExit(status: { id in
                        try await Task.detached { try ServiceClient.sessionStatus(renewing: id, identity: identity) }.value
                    }, stop: { id, revision in try await self.stop(id, revision: revision, identity: identity) })
                } else if network.mayOwnSession { throw ServiceClientError.unavailable }
            } catch {
                self.error = "退出前无法确认网络已恢复。\(error.localizedDescription)"
                terminating = false
                page = .overview
                showWindow()
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            if saveBeforeExit && dashboardHasChanges { saveDashboard() }
            heartbeat?.cancel()
            await updater.cancelForQuit()
            core.cancel()
            geodata.cancel()
            await session.shutdown()
            await logs.finishWrites()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
