import AppKit
import SwiftUI
import FreeV6System
import FreeV6Desktop

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    lazy var model: AppModel = {
        let model = AppModel()
        model.onShowWindow = { [weak self] in self?.revealWindow() }
        model.startMonitoring()
        return model
    }()
    override init() { super.init() }
    init(model: AppModel) {
        super.init()
        self.model = model
        model.onShowWindow = { [weak self] in self?.revealWindow() }
    }

    lazy var hideInitialWindow = model.startup.shouldStartHidden
    var openMainWindow: (() -> Void)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.beginTermination()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealWindow()
        if let window = sender.windows.first(where: { $0.identifier?.rawValue == "freev6-main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { openMainWindow?() }
        return false
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard hideInitialWindow, let window = notification.object as? NSWindow else { return }
        window.orderOut(nil)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard hideInitialWindow, let window = notification.object as? NSWindow,
              window.isVisible, window.occlusionState.contains(.visible) else { return }
        window.orderOut(nil)
    }
    func revealWindow() {
        hideInitialWindow = false
        NSApp.windows.first { $0.identifier?.rawValue == "freev6-main" }?.alphaValue = 1
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct WindowConfiguration: NSViewRepresentable {
    let delegate: ApplicationDelegate
    func makeNSView(context: Context) -> NSView {
        let view = MainWindowAnchor()
        view.applicationDelegate = delegate
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowAnchor: NSView {
    weak var applicationDelegate: ApplicationDelegate?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("freev6-main")
        window.delegate = applicationDelegate
        window.titleVisibility = .hidden
        // AppKit measures the entire window, including the system's current toolbar.
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("FreeV6MainWindow")
        if applicationDelegate?.hideInitialWindow == true {
            window.alphaValue = 0
            DispatchQueue.main.async { [weak window, weak applicationDelegate] in
                if applicationDelegate?.hideInitialWindow == true { window?.orderOut(nil) }
            }
        }
    }
}

struct FreeV6App: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @Environment(\.openWindow) private var openWindow

    private var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }

    var body: some Scene {
        let open = openWindow
        let _ = delegate.openMainWindow = { open(id: "main") }
        mainWindow
        Settings {
            StartupPreferences(model: model, showMenuBarExtra: $showMenuBarExtra)
                .preferredColorScheme(colorScheme)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 780, height: 550)
        .windowResizability(.contentSize)
        Window("FreeV6 使用说明", id: "help") {
            NativeHelpView().preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 560, height: 520)
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            StatusMenu(model: model)
        } label: {
            StatusIcon(model: model)
        }.menuBarExtraStyle(.menu)
    }

    private var mainWindow: some Scene {
        Window("FreeV6", id: "main") {
            StartupWindow(model: model)
                .preferredColorScheme(colorScheme)
                .background(WindowConfiguration(delegate: delegate))
                .frame(minWidth: 720)
        }
        .defaultSize(width: 920, height: 620)
        .windowToolbarStyle(.unified)
        .commands { NativeCommands(model: model) }
    }
}

private struct StartupPreferences: View {
    @ObservedObject var model: AppModel
    @Binding var showMenuBarExtra: Bool
    var body: some View {
        if model.startup.accepted { SettingsView(model: model, showMenuBarExtra: $showMenuBarExtra) }
        else { StartupNoticeView(model: model).frame(width: 560, height: 480) }
    }
}

private struct StartupWindow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.startup.accepted { MainView(model: model) }
        else { StartupNoticeView(model: model) }
    }
}

private struct StatusIcon: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Label("FreeV6 — \(model.connectionTitle)", systemImage: model.connectionSymbol)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        WindowPages(model: model)
            .toolbar { NativeToolbar(model: model) }
            .disabled(model.terminating || model.promptActive || model.updater.preparingInstallation)
    }
}

private struct WindowPages: View {
    let model: AppModel
    @ObservedObject private var navigation: WindowNavigation
    @State private var visited: Set<Page> = []

    init(model: AppModel) {
        self.model = model
        navigation = model.navigation
    }
    var body: some View {
        let selected = navigation.page
        // Keep visited pages in place, including the scroll position and node search.
        // Rebuilding an AppKit form/table on every click stalls the toolbar animation.
        ZStack {
            ForEach(Page.allCases) { destination in
                if destination == selected || visited.contains(destination) {
                    content(destination)
                        .opacity(destination == selected ? 1 : 0)
                        .allowsHitTesting(destination == selected)
                        .accessibilityHidden(destination != selected)
                        .disabled(destination != selected)
                }
            }
        }
            .onChange(of: selected, initial: true) { old, new in
                if !visited.contains(new) { visited.insert(new) }
                guard old != new, let window = NSApp.keyWindow,
                      window.identifier?.rawValue == "freev6-main", window.firstResponder is NSText else { return }
                window.makeFirstResponder(nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusedSceneValue(\.commandContext, .main(selected))
    }

    @ViewBuilder private func content(_ page: Page) -> some View {
        switch page {
        case .overview: OverviewView(model: model)
        case .nodes: NodesView(model: model)
        case .configuration:
            BusinessSettingsView(model: model.business, app: model, context: .main(.configuration))
        case .logs: DiagnosticsView(model: model)
        }
    }
}
