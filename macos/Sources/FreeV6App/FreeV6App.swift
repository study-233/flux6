import AppKit
import SwiftUI
import FreeV6System
import FreeV6Desktop

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var terminationHandler: () -> NSApplication.TerminateReply = { .terminateNow }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationHandler()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.identifier?.rawValue == "freev6-main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct WindowConfiguration: NSViewRepresentable {
    let delegate: ApplicationDelegate
    let model: AppModel
    func makeNSView(context: Context) -> NSView {
        let view = MainWindowAnchor()
        view.applicationDelegate = delegate
        delegate.terminationHandler = { model.beginTermination() }
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
        window.setFrameAutosaveName("FreeV6MainWindow")
    }
}

@main struct FreeV6App: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }

    var body: some Scene {
        Window("FreeV6", id: "main") {
            MainView(model: model)
                .preferredColorScheme(colorScheme)
                .background(WindowConfiguration(delegate: delegate, model: model))
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 920, height: 620)
        .windowToolbarStyle(.unified)
        .commands { NativeCommands(model: model) }
        Settings {
            SettingsView(model: model)
                .preferredColorScheme(colorScheme)
        }
        Window("FreeV6 使用说明", id: "help") {
            NativeHelpView().preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 560, height: 520)
        MenuBarExtra("FreeV6 — \(model.serviceState.title)", systemImage: model.serviceState.symbol) {
            StatusMenu(model: model)
        }.menuBarExtraStyle(.menu)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                Label(model.page?.title ?? "概览", systemImage: model.page?.symbol ?? "network")
                    .font(.largeTitle.bold())
                if model.page == .overview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ServiceOverviewView(model: model)
                            WarpAccountView(model: model.warp).disabled(model.serviceBusy)
                            RuntimePreparationView(model: model.core)
                            GeodataPreparationView(model: model.geodata)
                            ConfigurationPreparationView(model: model)
                        }
                    }
                } else if model.page == .configuration {
                    BusinessSettingsView(model: model.business, app: model, context: .main(.configuration))
                } else {
                    Text("此页面将在共享业务与网络服务接入后启用。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("macOS 原生客户端 · 开发版本")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
                .navigationTitle(model.page?.title ?? "概览")
                .toolbar { NativeToolbar(model: model) }
        }
        .focusedSceneValue(\.commandContext, .main(model.page ?? .overview))
        .disabled(model.terminating || model.promptActive)
    }
}

private struct ServiceOverviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.serviceStatus, systemImage: "wrench.and.screwdriver").font(.headline)
                Text("网络服务负责后续的 TUN 与网络恢复。当前版本只验证服务安装和身份，连接功能仍在开发。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(model.serviceInstalled ? "修复 / 重新登记服务…" : "安装网络服务…") {
                        Task { await model.manageService(.install) }
                    }.disabled(model.serviceBusy || model.warp.busy)
                    DesktopCommandButton(.refreshService, model: model)
                    if model.serviceBusy { ProgressView().controlSize(.small) }
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text("当前未启动代理，也未修改系统 DNS。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmUninstall = false
    @State private var selectedTab = PreferencesPage.general
    var body: some View {
        TabView(selection: $selectedTab) {
        Form {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
        }.padding(24).tabItem { Label("通用", systemImage: "gearshape") }.tag(PreferencesPage.general)
        BusinessSettingsView(model: model.business, app: model, context: .preferences(.rules)).tabItem { Label("代理规则", systemImage: "slider.horizontal.3") }.tag(PreferencesPage.rules)
        ScrollView { WarpAccountView(model: model.warp).padding(24).disabled(model.serviceBusy) }.tabItem { Label("WARP", systemImage: "key") }.tag(PreferencesPage.account)
        ScrollView {
            VStack(spacing: 20) {
                RuntimePreparationView(model: model.core)
                GeodataPreparationView(model: model.geodata)
            }.padding(24)
        }.tabItem { Label("核心与数据", systemImage: "shippingbox") }.tag(PreferencesPage.core)
        Form {
            Section("网络服务") {
                Text(model.serviceStatus)
                Button("恢复未完成的安装…") { Task { await model.manageService(.recover) } }.disabled(model.serviceBusy || model.warp.busy)
                Button("卸载网络服务…") { confirmUninstall = true }
                    .disabled(model.serviceBusy || model.warp.busy || !model.serviceInstalled)
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }.padding(24).tabItem { Label("网络服务", systemImage: "network") }.tag(PreferencesPage.service)
        }
        .frame(width: 560, height: 540)
        .focusedSceneValue(\.commandContext, .preferences(selectedTab))
        .disabled(model.terminating || model.promptActive)
        .confirmationDialog("卸载网络服务？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { Task { await model.manageService(.uninstall) } }
        } message: {
            Text("将移除后台网络服务。应用和用户配置会保留，之后可以重新安装服务。")
        }
    }
}
