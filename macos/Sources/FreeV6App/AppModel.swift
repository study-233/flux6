import AppKit
import Combine
import SwiftUI
import FreeV6Desktop
import FreeV6System
import FreeV6Business

typealias Page = DesktopPage

@MainActor final class AppModel: ObservableObject {
    @Published var page: Page? {
        didSet { if let page { defaults.set(page.rawValue, forKey: "lastPage") } }
    }
    @Published var error: String?
    @Published var serviceStatus = "正在检查网络服务…"
    @Published var serviceState = DesktopServiceState.checking
    @Published var serviceBusy = false
    @Published var serviceInstalled = false
    @Published private(set) var promptActive = false
    @Published private(set) var terminating = false
    @Published private var checkingConfiguration = false
    var configurationBusy: Bool { checkingConfiguration || network.phase.busy }
    let network = DesktopNetworkSession()
    let controls: DesktopCoreControls
    @Published var nodeGroup = SessionNodeGroup.access
    @Published private(set) var modeSaveError: String?
    private weak var trackedStatusMenu: NSMenu?
    @Published private(set) var trafficReport: TrafficReport?
    @Published private(set) var accountingError: String?
    private var lastObservation: TimeInterval = 0
    private var collectingTraffic = false
    private var trafficClock: Task<Void, Never>?
    private var serviceIdentity: CodeIdentity?
    private var heartbeat: Task<Void, Never>?
    var connectionTitle: String {
        serviceState == .ready || network.mayOwnSession ? network.phase.title : serviceState.title
    }
    var connectionSymbol: String {
        serviceState == .ready || network.mayOwnSession ? network.phase.symbol : serviceState.symbol
    }
    var canManageService: Bool {
        !serviceBusy && !warp.busy && !configurationBusy && !network.mayOwnSession &&
            (serviceState != .ready || network.phase == .idle)
    }
    @Published private(set) var configurationSummary: ConfigurationSummary?
    @Published private(set) var configurationError: String?
    @Published private(set) var configurationCheckedByService = false
    let business: BusinessModel
    let core: RuntimeModel
    let geodata: GeodataModel
    let warp: WarpModel
    private let session: BusinessSession
    private let defaults: UserDefaults
    private var observations: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controls = DesktopCoreControls(defaults: defaults)
        page = defaults.string(forKey: "lastPage").flatMap(Page.init(rawValue:)) ?? .overview
        session = BusinessSession()
        business = BusinessModel(session: session)
        core = RuntimeModel(session: session)
        geodata = GeodataModel(session: session)
        warp = WarpModel(session: session)
        // Commands depend on nested models, including text edits and progress.
        business.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        core.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        geodata.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        warp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        controls.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        network.$phase.sink { [weak self] phase in
            if phase != .running {
                self?.controls.bind(nil)
                self?.modeSaveError = nil
            }
        }.store(in: &observations)
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
        Task { await refreshService() }
        Task { await business.reload() }
        Task { await loadTrafficReport() }
        Task { await core.refresh() }
        Task { await geodata.refresh() }
    }

    deinit { heartbeat?.cancel(); trafficClock?.cancel() }

    var commandState: DesktopCommandState {
        var state = DesktopCommandState()
        state.service = serviceState
        state.network = network.phase
        state.canMeasureNodes = !controls.measuring && availableGroup != nil
        state.canTargetSession = network.canTargetSession
        state.coreBusy = core.busy || configurationBusy
        state.coreAvailable = core.package?.available == true
        state.coreCancelable = core.canCancel
        state.settingsBusy = business.busy || configurationBusy
        state.settingsLoaded = business.snapshot != nil
        state.settingsChanged = business.hasChanges
        state.promptActive = promptActive
        state.terminating = terminating
        state.credentialsBusy = warp.busy || configurationBusy
        state.credentialsPending = warp.hasPending
        state.configurationReady = configurationPrerequisite == nil
        state.configurationBusy = configurationBusy
        return state
    }

    var configurationPrerequisite: String? {
        if configurationBusy || warp.busy || business.busy || serviceBusy || core.busy || geodata.busy { return "请等待当前操作结束。" }
        if serviceState == .ready && network.phase != .idle { return "请先确认网络会话已停止。" }
        if business.snapshot == nil { return "请先载入代理规则。" }
        if business.hasChanges { return "请先保存代理规则，再检查连接配置。" }
        if warp.hasPending || warp.summary == nil { return "请先检查或注册已保存的 WARP 凭据。" }
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
            let summary = try await warp.withPreparedConfiguration(settings: settings, runtimeId: runtime.resourceId,
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

    private var trafficVisible: Bool {
        if trackedStatusMenu != nil { return true }
        guard NSApp.isActive, page == .overview else { return false }
        return NSApp.windows.contains { $0.identifier?.rawValue == "freev6-main" && $0.occlusionState.contains(.visible) }
    }

    private func acceptTrafficReport(_ report: TrafficReport) {
        if let previous = trafficReport,
           previous.total.upload > report.total.upload || previous.total.download > report.total.download { return }
        accountingError = nil
        if trafficReport != report { trafficReport = report }
    }

    private func loadTrafficReport() async {
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
        guard !terminating, network.runningTarget == query.target, let identity = serviceIdentity else {
            throw ServiceClientError.rejected("此会话已经变化，请重新查看连接状态。")
        }
        return try await Task.detached { try ServiceClient.control(query, identity: identity) }.value
    }

    private func refreshCoreControls(restoreChoices: Bool = false) async {
        let target = network.runningTarget
        controls.bind(target)
        guard let target else { return }
        await controls.inspect(using: exchange)
        guard restoreChoices, target == network.runningTarget else { return }
        for group in controls.state?.groups ?? [] {
            guard let last = controls.preferredMember(group.group), last != (group.automatic ? group.preferred : group.selected),
                  group.members.contains(last), let token = controls.state?.token else { continue }
            let request = SessionControlRequest(target, .select, token: token, group: group.group, member: last)
            guard await controls.change(request, using: exchange) else { break }
        }
    }

    func changeMode(_ mode: CoreMode, target: SessionControlTarget, token: UUID) async {
        guard !business.busy, let baseline = business.snapshot, target == network.runningTarget else { return }
        modeSaveError = nil
        let request = SessionControlRequest(target, .setMode, token: token, mode: mode)
        guard await controls.change(request, using: exchange), let preference = ProxyMode(rawValue: mode.rawValue) else { return }
        do { try await business.saveConfirmedMode(preference, baseline: baseline) }
        catch { modeSaveError = "本次模式已切换，默认模式保存失败。\(error.localizedDescription)" }
    }

    func useAutomaticSelection(target: SessionControlTarget, token: UUID) async {
        _ = await controls.change(SessionControlRequest(target, .unpin, token: token), using: exchange)
    }

    func selectMember(_ name: String, group: SessionNodeGroup, target: SessionControlTarget, token: UUID) async {
        let query = SessionControlRequest(target, .select, token: token, group: group, member: name)
        _ = await controls.change(query, using: exchange)
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

    private func connect() async {
        guard commandState.availability(.connect).enabled, let identity = serviceIdentity,
              let settings = business.snapshot, let runtime = core.package, let data = geodata.package else { return }
        await network.connect { token in
            try await CampusIPv6.check(developerMode: settings.settings.devMode)
            let cache = try WorkerLocation.application().cache
            let prepared = try await warp.withPreparedConfiguration(settings: settings, runtimeId: runtime.resourceId,
                                                                     geodataId: data.resourceId) { $0 }
            guard !business.hasChanges, business.snapshot?.revision == prepared.settingsRevision,
                  warp.summary?.revision == prepared.credentialRevision else { throw WorkerClientError.staleConfiguration }
            return try await Task.detached {
                let request = try Self.transfer(prepared, cache: cache, identity: identity)
                return try ServiceClient.startSession(request, idleToken: token, identity: identity)
            }.value
        }
        if network.phase == .unknown { await refreshNetwork() }
        else { await refreshCoreControls(restoreChoices: true) }
    }

    private func stop(_ id: UUID, revision: UInt64, identity: CodeIdentity) async throws -> NetworkSessionReply {
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
        switch command {
        case .showMain:
            openWindow(id: "main"); showWindow()
        case .showPage(let page):
            self.page = page; openWindow(id: "main"); showWindow()
        case .configureService, .showCore, .reviewSetup:
            page = .overview; openWindow(id: "main"); showWindow()
        case .refreshService: Task { await refreshService() }
        case .checkCore: Task { await core.refresh() }
        case .downloadCore: core.beginDownload()
        case .cancelCoreDownload: core.cancel()
        case .prepareConfiguration:
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
        case .connect: Task { await connect() }
        case .disconnect, .retryRecovery: Task { await disconnect() }
        case .measureNodes:
            if let group = availableGroup { Task { await measure(group: group.group, members: group.members) } }
        case .importChain, .refreshCloud, .exportLogs, .exportDiagnostics, .checkUpdates:
            break // Not advertised as available until their real implementations are connected.
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
    }

    func manageService(_ action: ServiceInstallationAction) async {
        guard canManageService, !terminating else { return }
        serviceBusy = true; serviceState = .managing; error = nil; configurationCheckedByService = false
        serviceStatus = "正在等待管理员授权…"
        defer { serviceBusy = false }
        do {
            let app = Bundle.main.bundleURL
            let identity = try CodeIdentity.protectedFile(at: app, identifier: "dev.freev6.desktop")
            let request = try ServiceInstallationRequest(action: action, app: app, uid: getuid(), clientHash: identity.cdHash)
            try await Task.detached { try request.execute() }.value
            await readServiceStatus()
        } catch {
            self.error = error.localizedDescription
            await readServiceStatus()
        }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "freev6-main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func beginTermination() -> NSApplication.TerminateReply {
        guard !terminating, !promptActive else { return .terminateCancel }
        let availability = commandState.availability(.quit)
        guard availability.enabled else {
            let alert = NSAlert()
            alert.messageText = "操作正在进行"
            alert.informativeText = availability.reason ?? "请等待当前操作结束。"
            alert.runModal()
            return .terminateCancel
        }
        var saveBeforeExit = false
        if business.hasChanges {
            promptActive = true
            let alert = NSAlert()
            alert.messageText = "退出前保存代理规则？"
            alert.informativeText = "未保存的更改将在退出后丢失。"
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "不保存退出")
            let response = alert.runModal()
            promptActive = false
            if response == .alertSecondButtonReturn { return .terminateCancel }
            saveBeforeExit = response == .alertFirstButtonReturn
        }
        terminating = true
        Task {
            if saveBeforeExit {
                await business.save()
                if business.error != nil || business.hasChanges {
                    terminating = false
                    page = .configuration; showWindow()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
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
            heartbeat?.cancel()
            core.cancel()
            geodata.cancel()
            await session.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
