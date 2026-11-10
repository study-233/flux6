import AppKit
import Combine
import FlutterMacOS
import FreeV6Host
import FreeV6Desktop
import FreeV6Business
import FreeV6System
import FreeV6UpdateSupport

/// macOS owns window lifetime and the single network coordinator; Dart owns page presentation.
@MainActor
final class HostApplication: NSObject, NSWindowDelegate {
    static let shared = HostApplication()
    static var isOfficial: Bool { Bundle.main.bundleIdentifier == "dev.freev6.desktop" }
    static let needsInstallation = isOfficial && (try? ApplicationLocation.requiresInstallation(at: Bundle.main.bundleURL)) != false
    #if FREEV6_RELEASE_HOST
    static var enabled: Bool { isOfficial && !needsInstallation }
    lazy var coordinator: Result<FreeV6HostCoordinator, Error> = Result { try FreeV6HostCoordinator.live() }
    #else
    static var isQA: Bool {
        let prefix = "dev.freev6.flutter-host.qa."
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(id.dropFirst(prefix.count))) != nil
    }
    static var enabled: Bool { (isOfficial && !needsInstallation) || isQA || Bundle.main.bundleIdentifier == "dev.freev6.flutter-host" }
    lazy var coordinator: Result<FreeV6HostCoordinator, Error> = Result {
        if Self.isOfficial { return try FreeV6HostCoordinator.live() }
        if Self.isQA, let seed = Bundle.main.object(forInfoDictionaryKey: "FreeV6QAStartupNotices") as? String {
            // Only the separately signed QA clone registers a process-local consent fixture.
            UserDefaults.standard.register(defaults: ["acceptedNotices": seed])
        }
        return try FreeV6HostCoordinator.preview()
    }
    #endif
    private(set) var main: HostWindowChannel?
    private(set) var settings: HostWindowChannel?
    private var settingsWindow: NSWindow?
    private var settingsController: FlutterViewController?
    private var wakeObserver: NSObjectProtocol?
    private var stateObserver: UUID?
    private var appliedIcon: String?
    private var appStarted = false
    private var userRevealed = false
    private var terminating = false
    private var confirmingClose = false
    private lazy var menus = HostMenus(app: self)
    private let updater = DesktopUpdater()
    private var updateObservation: AnyCancellable?

    func attachMain(_ window: NSWindow, controller: FlutterViewController) {
        window.title = Self.isOfficial ? "FreeV6" : "FreeV6 Flutter 集成验收"
        window.identifier = NSUserInterfaceItemIdentifier("freev6-main")
        window.delegate = self
        main = HostWindowChannel(window: window, role: "main", controller: controller, app: self)
        if let notices = Bundle.main.resourceURL.flatMap({ try? StartupNotices(directory: $0.appendingPathComponent("Notices")) }),
           DesktopStartup(defaults: .standard, notices: notices).shouldStartHidden {
            window.alphaValue = 0
        }
        // Nib outlets, including the application menu, finish wiring after awakeFromNib.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    func start() {
        menus.install()
        guard !appStarted else { return }
        appStarted = true
        if Self.isOfficial {
            updateObservation = updater.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.main?.uiAction("refresh")
                    self?.settings?.uiAction("refresh")
                }
            }
        }
        if let service = try? coordinator.get() {
            stateObserver = service.observe { [weak self] event in
                guard event["kind"] as? String != "traffic", let snapshot = event["snapshot"] as? [String: Any] else { return }
                self?.menus.apply(snapshot)
                self?.applyIcon(snapshot)
            }
            Task {
                let snapshot = await service.snapshot()
                menus.apply(snapshot)
                applyIcon(snapshot)
                let settings = snapshot["settings"] as? [String: Any]
                let prefs = settings?["preferences"] as? [String: Any]
                let accepted = settings?["accepted"] as? Bool ?? false
                let fallback = accepted && prefs?["hideOnStart"] as? Bool == true && prefs?["showMenuBar"] as? Bool != false
                if !userRevealed, snapshot["shouldStartHidden"] as? Bool ?? fallback {
                    main?.window?.orderOut(nil)
                }
                main?.window?.alphaValue = 1
            }
        } else {
            main?.window?.alphaValue = 1
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.runCommand("refresh", reportErrors: false) }
        }
    }

    private func applyIcon(_ snapshot: [String: Any]) {
        let settings = snapshot["settings"] as? [String: Any]
        let preferences = settings?["preferences"] as? [String: Any]
        let requested = preferences?["appIcon"] as? String ?? "cow"
        let icon = ["cow", "orange", "prism", "four-color", "earth"].contains(requested) ? requested : "cow"
        guard icon != appliedIcon, let image = NSImage(named: "cat-" + icon) else { return }
        NSApp.applicationIconImage = image
        appliedIcon = icon
    }

    func stopObserving() {
        updateObservation?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let stateObserver, let service = try? coordinator.get() { service.removeObserver(stateObserver) }
        settings?.close()
        main?.close()
        menus.remove()
    }

    func displaying(_ native: [String: Any]) -> [String: Any] {
        guard Self.isOfficial, var settings = native["settings"] as? [String: Any] else { return native }
        var state = native
        settings["update"] = ["available": !updater.busy, "status": updater.error ?? updater.status] as [String: Any]
        state["settings"] = settings
        return state
    }

    func showMain() {
        guard let window = main?.window else { return }
        userRevealed = true
        window.alphaValue = 1
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let project = FlutterDartProject()
            project.dartEntrypointArguments = ["/settings"]
            let controller = FlutterViewController(project: project)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 550),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentViewController = controller
            window.identifier = NSUserInterfaceItemIdentifier("freev6-settings")
            window.isReleasedWhenClosed = false
            window.title = "FreeV6 设置"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.contentMinSize = NSSize(width: 640, height: 440)
            // Assigning an unmounted Flutter controller adopts its initial one-point view.
            // Size the actual window after attaching the controller, as we do for the main window.
            controller.view.autoresizingMask = [.width, .height]
            MainFlutterWindow.resize(window, width: 780, height: 550)
            window.center()
            RegisterGeneratedPlugins(registry: controller)
            settingsWindow = window
            settingsController = controller
            settings = HostWindowChannel(window: window, role: "settings", controller: controller, app: self)
            window.delegate = self
        }
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let window = settingsWindow,
           let size = window.contentView?.bounds.size,
           size.width < window.contentMinSize.width || size.height < window.contentMinSize.height {
            MainFlutterWindow.resize(window, width: 780, height: 550)
            window.center()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if appStarted { menus.install() }
    }

    var focused: HostWindowChannel? { NSApp.keyWindow === settingsWindow && settingsWindow != nil ? settings : main }

    func runCommand(_ name: String, args: [String: Any] = [:], displayedContext: [String: Any]? = nil, reportErrors: Bool = true) async {
        do {
            let service = try coordinator.get()
            let state: [String: Any]
            if let displayedContext { state = displayedContext } else { state = await service.snapshot() }
            var envelope: [String: Any] = ["version": 1, "id": UUID().uuidString, "name": name, "arguments": args]
            for key in ["sessionId", "revision", "sessionRevision", "controlToken"] {
                envelope[key] = state[key] ?? NSNull()
            }
            let result = await service.command(envelope)
            if let snapshot = result["snapshot"] as? [String: Any] { menus.apply(snapshot) }
            if reportErrors, result["ok"] as? Bool != true {
                await showError(result["error"] as? String ?? "操作未完成，请重试。")
            }
        } catch { if reportErrors { await showError(error.localizedDescription) } }
    }

    private func showError(_ message: String) async {
        let alert = NSAlert()
        alert.messageText = "FreeV6"
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        if let window = focused?.window, window.attachedSheet == nil {
            window.makeKeyAndOrderFront(nil)
            _ = await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !confirmingClose, !terminating else { return false }
        guard let channel = sender === settingsWindow ? settings : main else { return true }
        confirmingClose = true
        Task {
            defer { confirmingClose = false }
            if await confirmEdits(channel) { dismiss(channel) }
        }
        return false
    }

    private func dismiss(_ channel: HostWindowChannel) {
        if channel === settings {
            channel.close()
            settingsWindow?.delegate = nil
            settingsWindow?.close()
            let engine = settingsController?.engine
            settingsWindow?.contentViewController = nil
            settings = nil
            settingsController = nil
            settingsWindow = nil
            engine?.shutDownEngine()
        } else { channel.window?.orderOut(nil) }
    }

    private func confirmEdits(_ channel: HostWindowChannel) async -> Bool {
        var dirty = channel.isDirty
        if !dirty, let service = try? coordinator.get() {
            let snapshot = await service.snapshot()
            let details = snapshot["settings"] as? [String: Any]
            dirty = (details?["drafts"] as? [String: Bool])?[channel.role] == true || channel.isDirty
        }
        guard dirty else { return true }
        guard let window = channel.window, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "保留这个窗口中的修改？"
        alert.informativeText = "保存修改后继续，或放弃当前窗口的未保存修改。"
        alert.addButton(withTitle: "保存并继续")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        window.makeKeyAndOrderFront(nil)
        let answer = await alert.beginSheetModal(for: window)
        guard answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn else { return false }
        let saved = await channel.resolveDrafts(saving: answer == .alertFirstButtonReturn)
        if !saved { await showError("修改未处理，窗口已保留。请检查表单后重试。") }
        return saved
    }

    private func confirmAllEdits() async -> Bool {
        for channel in [settings, main].compactMap({ $0 }) {
            if !(await confirmEdits(channel)) { return false }
        }
        return true
    }

    func requestQuit() {
        // terminate(:) waits inside a nested AppKit run loop after .terminateLater.
        // Enter from a run-loop event, leaving the main dispatch queue free for shutdown work.
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }

    func terminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard !confirmingClose else { return .terminateCancel }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            var allowed = false
            defer { terminating = false; application.reply(toApplicationShouldTerminate: allowed) }
            guard await confirmAllEdits() else { return }
            await updater.cancelForQuit()
            do {
                if let service = try? coordinator.get() { try await service.shutdown() }
                allowed = true
            } catch { await showError("退出前恢复未完成。\n" + error.localizedDescription) }
        }
        return .terminateLater
    }

    func checkUpdates() throws {
        let service = try coordinator.get()
        guard !terminating, !confirmingClose else { throw HostActionError.panelInUse }
        updater.check(prepare: { [weak self] release, source in
            guard let self, !self.terminating else { throw UpdateFailure.cancelled }
            let prompt = NSAlert()
            prompt.messageText = "安装更新并重新打开 FreeV6？"
            prompt.informativeText = "FreeV6 会先处理未保存的修改并恢复当前网络。"
            prompt.addButton(withTitle: "安装并重新打开")
            prompt.addButton(withTitle: "稍后")
            guard prompt.runModal() == .alertFirstButtonReturn, await self.confirmAllEdits() else { throw UpdateFailure.cancelled }
            try await service.prepareForUpdate()
            let record = try UpdateTransaction(sourceBuild: source, release: release)
            let store = UpdateTransactionStore(root: try WorkerLocation.application().data)
            try await Task.detached { try store.save(record) }.value
        }, install: { [weak self] in self?.requestQuit() })
    }
}
