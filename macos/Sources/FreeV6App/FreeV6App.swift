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
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier("freev6-main")
            view.window?.delegate = delegate
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
                .background(WindowConfiguration(delegate: delegate))
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
            }
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") { model.showWindow() }
            }
        }
        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
        MenuBarExtra("FreeV6", systemImage: "network") {
            Text(model.serviceStatus)
            Button("连接") {}.disabled(true)
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
                            Text("原生客户端正在开发。网络服务通过验证并安装后，即可建立连接。")
                                .foregroundStyle(.secondary)
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
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Text("网络与启动设置将在对应服务接入后提供。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 420)
    }
}
