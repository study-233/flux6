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
    @Published private(set) var configurationBusy = false
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
        Task { await refreshService() }
        Task { await business.reload() }
        Task { await core.refresh() }
        Task { await geodata.refresh() }
    }

    var commandState: DesktopCommandState {
        var state = DesktopCommandState()
        state.service = serviceState
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
        configurationBusy = true; configurationError = nil; configurationSummary = nil; configurationCheckedByService = false
        let useService = serviceState == .ready
        defer { configurationBusy = false }
        do {
            let cache = try WorkerLocation.application().cache
            let summary = try await warp.withPreparedConfiguration(settings: settings, runtimeId: runtime.resourceId,
                                                                   geodataId: data.resourceId) { prepared in
                if useService {
                    try await Task.detached {
                        guard let identity = try InstalledServiceStatus.identity() else { throw ServiceClientError.unavailable }
                        try ServiceResourceTransfer.prepare(cache: cache, runtimeID: prepared.runtimeId,
                                                            geodataID: prepared.geodataId, identity: identity)
                        let request = ConfigurationCheckRequest(runtimeID: prepared.runtimeId, geodataID: prepared.geodataId,
                            settingsRevision: prepared.settingsRevision, credentialRevision: prepared.credentialRevision,
                            configuration: prepared.configuration)
                        _ = try ServiceClient.checkConfiguration(request, identity: identity)
                    }.value
                }
                return ConfigurationSummary(prepared)
            }
            guard business.snapshot?.revision == settings.revision, !business.hasChanges else { throw WorkerClientError.staleConfiguration }
            configurationSummary = summary
            configurationCheckedByService = useService
        } catch { configurationError = error.localizedDescription }
    }

    func perform(_ command: DesktopCommand, in context: CommandContext, openWindow: OpenWindowAction) {
        // Revalidate at execution, even if a menu was opened before state changed.
        guard commandState.availability(command, in: context).enabled else { return }
        switch command {
        case .showMain:
            openWindow(id: "main"); showWindow()
        case .showPage(let page):
            self.page = page; openWindow(id: "main"); showWindow()
        case .configureService, .showCore:
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
        case .connect, .importChain, .refreshCloud, .measureNodes, .exportLogs, .exportDiagnostics, .checkUpdates:
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
        let result = await Task.detached { try InstalledServiceStatus.check() }.result
        switch result {
        case .success(let reply):
            serviceInstalled = reply != nil
            serviceState = reply == nil ? .missing : .ready
            serviceStatus = reply == nil ? "网络服务尚未安装" : "网络服务已就绪 · \(reply!.serviceVersion)"
        case .failure(let failure):
            serviceInstalled = true; serviceState = .needsRepair
            serviceStatus = "网络服务需要修复"
            error = failure.localizedDescription
        }
    }

    func manageService(_ action: ServiceInstallationAction) async {
        guard !serviceBusy, !warp.busy, !configurationBusy, !terminating else { return }
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
            core.cancel()
            geodata.cancel()
            await session.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
