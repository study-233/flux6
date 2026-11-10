import AppKit
import SwiftUI
import FreeV6Desktop

struct SidebarDestination: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
        }
    }
}

private extension PreferencesPage {
    var title: String {
        switch self {
        case .general: "通用"
        case .rules: "代理规则"
        case .account: "WARP 账户"
        case .core: "核心与数据"
        case .service: "网络服务"
        }
    }

    var label: SidebarDestination {
        switch self {
        case .general: SidebarDestination(title: title, symbol: "gearshape.fill", color: .gray)
        case .rules: SidebarDestination(title: title, symbol: "slider.horizontal.3", color: .indigo)
        case .account: SidebarDestination(title: title, symbol: "key.fill", color: .orange)
        case .core: SidebarDestination(title: title, symbol: "shippingbox.fill", color: .teal)
        case .service: SidebarDestination(title: title, symbol: "network", color: .blue)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var showMenuBarExtra: Bool
    @AppStorage("appearance") private var appearance = "system"
    @State private var selection: PreferencesPage? = .general
    @State private var sidebarVisible = true
    @State private var confirmUninstall = false

    var body: some View {
        HSplitView {
            if sidebarVisible {
                List(selection: $selection) {
                    Section("偏好设置") {
                        ForEach([PreferencesPage.general, .rules], id: \.self) { page in page.label.padding(.vertical, 3).tag(page) }
                    }
                    Section("账户与维护") {
                        ForEach([PreferencesPage.account, .core, .service], id: \.self) { page in page.label.padding(.vertical, 3).tag(page) }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("设置分类")
                .frame(minWidth: 156, idealWidth: 180, maxWidth: 204)
            }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle((selection ?? .general).title)
        .background(SettingsTitlebarToggle(isVisible: $sidebarVisible))
        .frame(minWidth: 640, idealWidth: 780, maxWidth: .infinity,
               minHeight: 402, idealHeight: 520, maxHeight: .infinity)
        .focusedSceneValue(\.commandContext, .preferences(selection ?? .general))
        .disabled(model.terminating || model.promptActive || model.updater.preparingInstallation)
        .confirmationDialog("卸载网络服务？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { Task { await model.manageService(.uninstall) } }
        } message: {
            Text("将移除后台网络服务。应用和用户配置会保留，之后可以重新安装服务。")
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general:
            Form {
                Section("外观") {
                    Picker("外观模式", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.segmented)
                }
                Section("菜单栏") {
                    Toggle("在菜单栏中显示 FreeV6", isOn: $showMenuBarExtra)
                    if !showMenuBarExtra {
                        Text(model.startup.silent ? "菜单栏入口已隐藏，启动时会显示主窗口。" : "可以从程序坞重新打开主窗口。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                StartupSettingsView(startup: model.startup)
            }.formStyle(.grouped).toggleStyle(.switch)
        case .rules:
            BusinessSettingsView(model: model.business, app: model, context: .preferences(.rules))
        case .account:
            ScrollView {
                WarpAccountView(model: model.warp).padding(20)
                    .disabled(interfaceFixture || model.serviceBusy || model.configurationBusy)
            }
        case .core:
            ScrollView {
                VStack(spacing: 16) {
                    RuntimePreparationView(model: model.core)
                    GeodataPreparationView(model: model.geodata)
                }.padding(20).disabled(interfaceFixture || model.configurationBusy)
            }
        case .service:
            Form {
                Section("网络服务") {
                    LabeledContent("状态", value: model.serviceStatus)
                    Button(model.serviceInstalled ? "修复或重新登记服务…" : "安装网络服务…") {
                        Task { await model.manageService(.install) }
                    }.disabled(!model.canManageService)
                    Button("恢复未完成的安装…") { Task { await model.manageService(.recover) } }
                        .disabled(!model.canManageService)
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    Button("卸载网络服务…", role: .destructive) { confirmUninstall = true }
                        .disabled(!model.canManageService || !model.serviceInstalled)
                }
            }.formStyle(.grouped)
        }
    }
}

// Settings scenes can place SwiftUI toolbar items in a separate row below the
// title. A title-bar accessory stays beside the window controls on every page.
private struct SettingsTitlebarToggle: NSViewRepresentable {
    @Binding var isVisible: Bool
    func makeNSView(context: Context) -> SettingsTitlebarAnchor { SettingsTitlebarAnchor() }
    func updateNSView(_ view: SettingsTitlebarAnchor, context: Context) {
        view.toggle = { isVisible.toggle() }
        view.setVisibleLabel(isVisible)
    }
}

private final class SettingsTitlebarAnchor: NSView {
    var toggle: (() -> Void)?
    private weak var host: NSWindow?
    private let accessory = NSTitlebarAccessoryViewController()
    private let button = NSButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.target = self
        button.action = #selector(activateSidebar)
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = [.control, .command]
        button.frame = NSRect(x: 4, y: 0, width: 32, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 42, height: 24))
        container.addSubview(button)
        accessory.view = container
        accessory.layoutAttribute = .left
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== host else { return }
        if let host, let i = host.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            host.removeTitlebarAccessoryViewController(at: i)
        }
        host = window
        if let window {
            window.addTitlebarAccessoryViewController(accessory)
            window.minSize = NSSize(width: 640, height: 440)
        }
    }
    func setVisibleLabel(_ visible: Bool) {
        let label = visible ? "隐藏设置侧栏" : "显示设置侧栏"
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
    @objc private func activateSidebar() { toggle?() }
}
