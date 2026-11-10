// Standalone UI fixture. The shipping app never links this entry point.
import SwiftUI
import QuartzCore
import Darwin
import FreeV6Business
import FreeV6Desktop
@testable import FreeV6System

@MainActor private final class FixtureSession {
    let id = UUID()
    let names = ["校园 IPv6 · 东区", "校园 IPv6 · 西区", "校园 IPv6 · 北区"]
    private var preferred: String?
    private var sample = 0
    private var token = UUID()
    private var mode = CoreMode.rule
    var failNextRead = false
    var failNextChange = false
    var emptyGroup = false
    var zeroRate = false

    func exchange(_ request: SessionControlRequest) throws -> SessionControlReply {
        if request.action == .inspect && failNextRead {
            failNextRead = false
            throw ServiceClientError.rejected("节点读取超时，请重试。")
        }
        if [.select, .unpin, .setMode].contains(request.action) && failNextChange {
            failNextChange = false
            throw ServiceClientError.rejected("服务未确认这次更改，请重试。")
        }
        switch request.action {
        case .select: preferred = request.member; token = UUID()
        case .unpin: preferred = nil; token = UUID()
        case .delay:
            return SessionControlReply(request, delay: .measured(milliseconds: preferred == request.member ? 12 : 28))
        case .traffic:
            let profile = [2, 3, 2, 6, 8, 7, 4, 6, 5, 4, 6, 3]
            let n = zeroRate ? 0 : UInt64(profile[sample % profile.count])
            sample += 1
            let traffic = CoreTrafficSample(up: n * 31250, down: n * 232000, upTotal: 2_800_000, downTotal: 18_200_000)
            return SessionControlReply(request, traffic: traffic)
        case .setMode: mode = request.mode ?? mode; token = UUID()
        case .inspect: break
        }
        let nodes = SessionNodeList(group: .access, selected: emptyGroup ? nil : preferred ?? names[0], preferred: emptyGroup ? nil : preferred,
                                    automatic: true, members: emptyGroup ? [] : names)
        let snapshot = SessionControlSnapshot(token: token, mode: mode, groups: [nodes])
        return SessionControlReply(request, state: snapshot)
    }

    func present(_ phase: NetworkSessionPhase, in model: AppModel) async throws {
        if phase == .running, model.network.runningTarget == nil {
            mode = model.business.snapshot.flatMap { CoreMode(rawValue: $0.settings.mode.rawValue) } ?? .rule
            preferred = nil
            token = UUID()
        }
        model.serviceState = .ready
        model.serviceStatus = "网络服务已就绪"
        model.serviceInstalled = true
        model.updateRecoveryBlocksConnection = false
        var fields: [String: Any] = ["protocolVersion": ServiceProtocolVersion.current, "requestID": UUID().uuidString,
                                     "phase": phase.rawValue, "sessionID": id.uuidString, "revision": 1,
                                     "settingsRevision": 1, "credentialRevision": id.uuidString]
        if phase == .stopped {
            fields = ["protocolVersion": ServiceProtocolVersion.current, "requestID": UUID().uuidString,
                      "phase": phase.rawValue, "idleToken": UUID().uuidString]
        }
        let reply = try JSONDecoder().decode(NetworkSessionReply.self, from: JSONSerialization.data(withJSONObject: fields))
        if phase == .stopped && model.network.canTargetSession {
            try await model.network.disconnect { _, _ in reply }
        } else { await model.network.refresh { _ in reply } }
        if phase == .running || phase == .stopped {
            UserDefaults.standard.set(phase == .stopped, forKey: "fixtureStopped")
        }
        let target = model.network.runningTarget
        model.controls.bind(target)
        if target != nil {
            await model.refreshCoreControls(restoreChoices: true)
            for _ in 0..<12 {
                _ = await model.controls.sample(using: exchange)
                try await Task.sleep(for: .milliseconds(90))
            }
        }
    }
}

// Measures main-run-loop delivery during repeated *real* view switches, not GPU FPS.
// The sampler is linked only into the fixture and never into the shipped app.
@MainActor private final class NavigationFrameSample {
    private var link: CADisplayLink?
    private var times = [Double]()
    private var previous: Double?
    private var active = false
    func run(model: AppModel, window: NSWindow) async {
        guard !active, let view = window.contentView else { return }
        active = true
        let original = model.page
        defer { active = false; model.page = original }
        times.removeAll(keepingCapacity: true)
        previous = nil
        let link = view.displayLink(target: self, selector: #selector(frame))
        self.link = link
        link.add(to: .main, forMode: .common)
        for step in 0..<32 {
            model.page = Page.allCases[step % Page.allCases.count]
            try? await Task.sleep(for: .milliseconds(105))
        }
        link.invalidate()
        self.link = nil
        let sorted = times.sorted()
        guard !sorted.isEmpty else { return }
        func percentile(_ p: Double) -> Double { sorted[Int(Double(sorted.count - 1) * p)] }
        let report = String(format: "switches=32 samples=%d interval_ms_median=%.1f p95=%.1f max=%.1f over_50_ms=%d\n",
                            sorted.count, percentile(0.5), percentile(0.95), sorted.last!, sorted.filter { $0 > 50 }.count)
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        try? report.write(to: folder.appendingPathComponent("navigation-frame-sample.txt"), atomically: true, encoding: .utf8)
    }
    @objc private func frame() {
        let now = CACurrentMediaTime()
        if let previous { times.append((now - previous) * 1000) }
        previous = now
    }
}

@MainActor private final class FixtureLifecycle: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.beginTermination() ?? .terminateNow
    }
}

@main private struct InterfaceStates: App {
    @NSApplicationDelegateAdaptor(FixtureLifecycle.self) private var lifecycle
    private let session = FixtureSession()
    private let navigationSample = NavigationFrameSample()
    @StateObject private var model: AppModel
    private let windowDelegate: ApplicationDelegate
    @State private var failure: String?
    @State private var showWelcome = false
    @AppStorage("showMenuBarExtra") private var showMenuBar = true
    @AppStorage("appearance") private var appearance = "system"
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    init() {
        // Foundation can return /var again after resolving /private/var on macOS.
        // The event journal intentionally rejects symlink ancestors; use the physical system temp directory.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            fatalError("无法打开隔离测试目录")
        }
        let temp = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        // Both fixture bundles have separate defaults domains. Retain only their own
        // synthetic settings and journal so quitting/reopening exercises real persistence.
        let defaults = UserDefaults.standard
        let fixtureID = defaults.string(forKey: "fixtureStoreID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(fixtureID.uuidString, forKey: "fixtureStoreID")
        let root = temp.appendingPathComponent("freev6-ui-" + fixtureID.uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let location = WorkerLocation(
            executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/freev6-worker"),
            data: root.appendingPathComponent("data"), resources: Bundle.main.resourceURL!,
            cache: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        let session = self.session
        let model = AppModel(workerLocation: location) { request, _ in try session.exchange(request) }
        // This bundle contains only test notices and has its own defaults domain.
        model.fixtureAccessNodeNames = session.names
        model.startup.acceptNotices()
        model.handleFixtureCommand = { [weak model] command in
            guard let model else { return true }
            switch command {
            case .disconnect, .retryRecovery, .connect:
                Task {
                    do { try await session.present(command == .connect ? .running : .stopped, in: model) }
                    catch { model.error = error.localizedDescription }
                }
            case .configureService, .reviewSetup, .showCore, .showPage, .showMain, .help, .quit,
                 .saveConfiguration, .reloadConfiguration, .importChain, .measureNodes, .exportLogs, .exportDiagnostics:
                return false
            default: break
            }
            return true
        }
        _model = StateObject(wrappedValue: model)
        windowDelegate = ApplicationDelegate(model: model)
    }

    var body: some Scene {
        let _ = lifecycle.model = model
        Window("FreeV6 界面测试", id: "main") {
            Group {
                if showWelcome { StartupNoticeView(model: model, onAccept: { showWelcome = false }) }
                else { MainView(model: model) }
            }.preferredColorScheme(scheme).frame(minWidth: 720)
                .background(WindowConfiguration(delegate: windowDelegate))
                .overlay(alignment: .bottom) { if let failure { Text(failure).foregroundStyle(.red) } }
                .task {
                    await model.business.reload()
                    await model.business.refreshNotice()
                    if let worker = try? model.session.worker(),
                       let report = try? await worker.trafficReport(),
                       report.total.upload == 0, report.total.download == 0 {
                        _ = try? await worker.observeTraffic(sessionID: session.id,
                            upload: 85_600_000, download: 336_000_000)
                    }
                    await model.loadTrafficReport()
                    await show(UserDefaults.standard.bool(forKey: "fixtureStopped") ? .stopped : .running)
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        if model.network.phase == .running { _ = await model.controls.sample(using: session.exchange) }
                    }
                }
        }.defaultSize(width: 920, height: 620)
        .windowToolbarStyle(.unified)
        .commands {
            NativeCommands(model: model)
            CommandMenu("测试场景") {
                Button("首次阅读") { showWelcome = true }
                Button("未连接") { showWelcome = false; Task { await show(.stopped) } }
                Button("首次连接准备") {
                    showWelcome = false
                    Task {
                        await show(.stopped)
                        model.serviceState = .missing
                        model.serviceInstalled = false
                        model.serviceStatus = "请先设置网络服务。"
                    }
                }
                Button("已连接") { showWelcome = false; Task { await show(.running) } }
                Button("连续切页检查") {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "freev6-main" }) {
                        Task { await navigationSample.run(model: model, window: window) }
                    }
                }
                Button("默认窗口") { resizeWindow(width: 920, height: 620) }
                Button("最小窗口") { resizeWindow(width: 720, height: 480) }
                Button("最小设置窗口") {
                    if let window = NSApp.keyWindow, window.identifier?.rawValue != "freev6-main" {
                        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 640, height: 440)), display: true)
                    }
                }
                Button("切换零速率") {
                    session.zeroRate.toggle()
                    Task { if model.network.runningTarget != nil { _ = await model.controls.sample(using: session.exchange) } }
                }
                Button("下次节点读取超时") {
                    session.failNextRead = true
                    Task { await model.refreshCoreControls() }
                }
                Button("下次切换失败") { session.failNextChange = true }
                Button("下次默认模式保存失败") { model.failNextDefaultSave = true }
                Button("切换空节点组") {
                    session.emptyGroup.toggle()
                    Task { await model.refreshCoreControls() }
                }
                Button("浅色外观") { appearance = "light" }
                Button("深色外观") { appearance = "dark" }
                Button("保存窗口预览") { savePreview() }
                Button("恢复失败") { Task { await show(.recoveryRequired) } }
            }
            CommandMenu("状态菜单预览") { StatusMenu(model: model) }
        }
        Settings {
            SettingsView(model: model, showMenuBarExtra: $showMenuBar).preferredColorScheme(scheme)
        }.windowToolbarStyle(.unified).defaultSize(width: 780, height: 550).windowResizability(.contentSize)
        Window("FreeV6 使用说明", id: "help") {
            NativeHelpView().preferredColorScheme(scheme)
        }.defaultSize(width: 560, height: 520)
        MenuBarExtra(isInserted: $showMenuBar) { StatusMenu(model: model) }
            label: { Label("FreeV6 界面测试", systemImage: "network") }
    }

    private func resizeWindow(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "freev6-main" }) else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setFrame(NSRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height),
                        display: true)
    }

    private func savePreview() {
        guard let window = NSApp.keyWindow, let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Previews")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let state = model.dashboardDraft == nil ? "normal" : "editing"
            let style = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
            let filename = "\(model.page?.rawValue ?? "overview")-\(state)-\(Int(window.frame.width))-\(style).png"
            try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch { failure = error.localizedDescription }
    }

    private func show(_ phase: NetworkSessionPhase) async {
        model.page = .overview
        do { try await session.present(phase, in: model) }
        catch { failure = error.localizedDescription }
    }
}
