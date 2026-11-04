import AppKit
import SwiftUI
import FreeV6System

enum Page: String, CaseIterable, Identifiable {
    case overview = "概览", nodes = "节点", configuration = "配置", logs = "日志"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "network"
        case .nodes: return "point.3.connected.trianglepath.dotted"
        case .configuration: return "slider.horizontal.3"
        case .logs: return "text.alignleft"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var page: Page? = .overview
    @Published var error: String?
    @Published var serviceStatus = "网络服务尚未安装"
    @Published var serviceBusy = false
    @Published var serviceInstalled = false

    init() { Task { await refreshService() } }

    func refreshService() async {
        guard !serviceBusy else { return }
        serviceBusy = true
        error = nil
        serviceStatus = "正在检查网络服务…"
        defer { serviceBusy = false }
        await readServiceStatus()
    }

    private func readServiceStatus() async {
        let result = await Task.detached { try InstalledServiceStatus.check() }.result
        switch result {
        case .success(let reply):
            serviceInstalled = reply != nil
            serviceStatus = reply == nil ? "网络服务尚未安装" : "网络服务已就绪 · \(reply!.serviceVersion)"
        case .failure(let failure):
            serviceInstalled = true
            serviceStatus = "网络服务需要修复"
            error = failure.localizedDescription
        }
    }

    func manageService(_ action: ServiceInstallationAction) async {
        guard !serviceBusy else { return }
        serviceBusy = true
        error = nil
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
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var canTerminate: () -> Bool = { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard canTerminate() else {
            let alert = NSAlert()
            alert.messageText = "网络服务操作正在进行"
            alert.informativeText = "请等待服务检查或安装操作结束。如果系统正在询问授权，也可以取消授权。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first(where: { $0.identifier?.rawValue == "freev6-main" })?.makeKeyAndOrderFront(nil)
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
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier("freev6-main")
            view.window?.delegate = delegate
            delegate.canTerminate = { !model.serviceBusy }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element.id) { index, page in
                    Button(page.rawValue) { model.page = page; model.showWindow() }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            CommandMenu("连接") {
                Button("连接") {}.disabled(true).keyboardShortcut("k", modifiers: [.command, .shift])
                Text(model.serviceStatus)
                Divider()
                Button("设置网络服务…") { model.page = .overview; model.showWindow() }
                Button("刷新服务状态") { Task { await model.refreshService() } }.disabled(model.serviceBusy)
            }
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") { model.showWindow() }
            }
        }
        Settings {
            SettingsView(model: model)
                .preferredColorScheme(colorScheme)
        }
        MenuBarExtra("FreeV6", systemImage: "network") {
            Text(model.serviceStatus)
            Button("连接") {}.disabled(true)
            Button("设置网络服务…") { model.page = .overview; model.showWindow() }
            Divider()
            Button("打开主窗口") { model.showWindow() }
            Button("设置…") { model.openSettings() }
            Divider()
            Button("退出 FreeV6") { NSApp.terminate(nil) }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                Label(model.page?.rawValue ?? "概览", systemImage: model.page?.symbol ?? "network")
                    .font(.largeTitle.bold())
                if model.page == .overview {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(model.serviceStatus, systemImage: "wrench.and.screwdriver")
                                .font(.headline)
                            Text("网络服务负责后续的 TUN 与网络恢复。当前版本只验证服务安装和身份，连接功能仍在开发。")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(model.serviceInstalled ? "修复 / 重新登记服务…" : "安装网络服务…") {
                                    Task { await model.manageService(.install) }
                                }.disabled(model.serviceBusy)
                                Button("刷新状态") { Task { await model.refreshService() } }.disabled(model.serviceBusy)
                                if model.serviceBusy { ProgressView().controlSize(.small) }
                            }
                            if let error = model.error {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            Text("当前未启动代理，也未修改系统 DNS。")
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                } else {
                    Text("此页面将在共享业务与网络服务接入后启用。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("macOS 原生客户端 · 开发版本")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
                .navigationTitle(model.page?.rawValue ?? "概览")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Label("未连接", systemImage: "circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("当前未连接")
                        Button("连接", action: {}).disabled(true)
                            .help("网络服务尚未安装")
                    }
                }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmUninstall = false
    var body: some View {
        Form {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Section("网络服务") {
                Text(model.serviceStatus)
                Button("恢复未完成的安装…") { Task { await model.manageService(.recover) } }.disabled(model.serviceBusy)
                Button("卸载网络服务…") { confirmUninstall = true }
                    .disabled(model.serviceBusy || !model.serviceInstalled)
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
        .padding(24).frame(width: 460)
        .confirmationDialog("卸载网络服务？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { Task { await model.manageService(.uninstall) } }
        } message: {
            Text("将移除后台网络服务。应用和用户配置会保留，之后可以重新安装服务。")
        }
    }
}
