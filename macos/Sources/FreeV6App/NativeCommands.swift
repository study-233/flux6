import AppKit
import SwiftUI
import FreeV6Desktop
import FreeV6System

private struct CommandContextKey: FocusedValueKey { typealias Value = CommandContext }
extension FocusedValues {
    var commandContext: CommandContext? {
        get { self[CommandContextKey.self] }
        set { self[CommandContextKey.self] = newValue }
    }
}

struct DesktopCommandButton: View {
    let command: DesktopCommand
    @ObservedObject var model: AppModel
    let context: CommandContext
    @Environment(\.openWindow) private var openWindow

    init(_ command: DesktopCommand, model: AppModel, context: CommandContext = .application) {
        self.command = command; self.model = model; self.context = context
    }
    var body: some View {
        let availability = model.commandState.availability(command, in: context)
        Button {
            model.perform(command, in: context, openWindow: openWindow)
        } label: {
            Label(command.title, systemImage: command.symbol)
        }
        .disabled(!availability.enabled)
        .help(availability.reason ?? command.title)
        .accessibilityLabel(command.title)
    }
}

struct NativeCommands: Commands {
    @ObservedObject var model: AppModel
    @FocusedValue(\.commandContext) private var context
    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        CommandGroup(after: .appInfo) {
            DesktopCommandButton(.checkUpdates, model: model)
        }
        CommandGroup(replacing: .newItem) {
            DesktopCommandButton(.importChain, model: model, context: context ?? .application).keyboardShortcut("o")
            Divider()
            DesktopCommandButton(.saveConfiguration, model: model, context: context ?? .application).keyboardShortcut("s")
            DesktopCommandButton(.reloadConfiguration, model: model, context: context ?? .application)
            Divider()
            DesktopCommandButton(.exportLogs, model: model, context: context ?? .application)
            DesktopCommandButton(.exportDiagnostics, model: model)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element.id) { index, page in
                DesktopCommandButton(.showPage(page), model: model)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Menu("日志级别") { LogLevelPicker(logs: model.logs).pickerStyle(.inline) }
                .disabled(context != .main(.logs) || model.promptActive || model.terminating)
            LogActions(logs: model.logs)
                .disabled(context != .main(.logs) || model.promptActive || model.terminating)
        }
        CommandMenu("连接") {
            DesktopCommandButton(model.commandState.primaryCommand, model: model).keyboardShortcut("k", modifiers: [.command, .shift])
            Text(model.connectionTitle)
            RuntimeMenus(model: model).disabled(!model.startup.accepted)
            Divider()
            DesktopCommandButton(.showPage(.configuration), model: model)
            DesktopCommandButton(.measureNodes, model: model)
            DesktopCommandButton(.refreshCloud, model: model)
            DesktopCommandButton(.prepareConfiguration, model: model)
            Divider()
            if model.commandState.primaryCommand != .configureService {
                DesktopCommandButton(.configureService, model: model)
            }
            if model.commandState.primaryCommand != .refreshService {
                DesktopCommandButton(.refreshService, model: model)
            }
            Menu("网络核心") {
                DesktopCommandButton(.downloadCore, model: model)
                DesktopCommandButton(.checkCore, model: model)
                DesktopCommandButton(.cancelCoreDownload, model: model)
            }
        }
        CommandGroup(after: .windowArrangement) {
            DesktopCommandButton(.showMain, model: model)
        }
        CommandGroup(replacing: .help) {
            DesktopCommandButton(.help, model: model)
        }
    }
}

struct NativeToolbar: ToolbarContent {
    @ObservedObject var model: AppModel
    var body: some ToolbarContent {
        let navigation = ToolbarItem(placement: .principal) {
            ToolbarPageSelector(navigation: model.navigation)
        }
        let status = ToolbarItem(placement: .primaryAction) {
            WindowSessionStatus(model: model).id(model.connectionTitle)
        }
        let action = ToolbarItem(placement: .primaryAction) {
            WindowSessionAction(model: model).id(model.commandState.primaryCommand.title)
        }
        if #available(macOS 26.0, *) {
            navigation.sharedBackgroundVisibility(.hidden)
            status.sharedBackgroundVisibility(.hidden)
            action.sharedBackgroundVisibility(.hidden)
        } else {
            navigation
            status
            action
        }
    }
}

private struct WindowSessionStatus: View {
    @ObservedObject var model: AppModel
    private var tint: Color {
        if model.serviceState == .needsRepair || model.serviceState == .missing { return .orange }
        switch model.network.phase {
        case .running: return .green
        case .recovering, .occupied: return .orange
        case .connecting, .disconnecting: return .accentColor
        default: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(model.connectionTitle).font(.callout)
        }
        .fixedSize().accessibilityElement(children: .ignore)
        .accessibilityLabel("连接状态：" + model.connectionTitle)
        .help(model.network.statusError ?? model.network.error ?? model.connectionTitle)
    }
}

private struct WindowSessionAction: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let command = model.commandState.primaryCommand
        let available = model.commandState.availability(command)
        Button {
            model.perform(command, in: .application, openWindow: openWindow)
        } label: {
            Text(command.title).font(.callout.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 11).frame(height: 27)
                .foregroundStyle(command == .connect ? Color.accentColor : .primary)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)) }
        }
        .buttonStyle(ControlPressStyle()).disabled(!available.enabled)
        .help(available.reason ?? command.title).accessibilityLabel(command.title)
        .fixedSize()
    }
}

struct StatusMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.connectionTitle)
        if let message = model.startup.automaticStatus { Text(message) }
        if let error = model.network.statusError ?? model.network.error { Text(error) }
        if model.network.phase == .running {
            if let mode = model.controls.state?.mode { Text("运行模式 · " + mode.title) }
            if let list = model.availableGroup, let selected = list.selected { Text(list.group.title + " · " + selected) }
            TrafficRates(controls: model.controls)
        }
        DesktopCommandButton(model.commandState.primaryCommand, model: model)
        Divider()
        RuntimeModeSection(model: model).disabled(!model.startup.accepted)
        RuntimeNodeMenu(model: model).disabled(!model.startup.accepted)
        if let error = model.modeSaveError ?? model.controls.error { Text(error) }
        DesktopCommandButton(.showPage(.configuration), model: model)
        Menu("网络核心") {
            Text(model.core.status)
            Text(model.warp.status)
            Divider()
            DesktopCommandButton(.downloadCore, model: model)
            DesktopCommandButton(.checkCore, model: model)
            DesktopCommandButton(.cancelCoreDownload, model: model)
        }
        Divider()
        DesktopCommandButton(.showMain, model: model)
        SettingsLink { Text("设置…") }.disabled(model.terminating || model.promptActive)
        DesktopCommandButton(.help, model: model)
        Divider()
        DesktopCommandButton(.quit, model: model)
    }
}

struct NativeHelpView: View {
    var body: some View {
        Form {
            Section("开始使用") {
                Text("断开时仍可选择下次连接的模式和节点，连接后可以测速。\n从仪表盘设置网络服务、下载核心与规则数据。默认出口和链式代理需要 WARP 账户；已启用的备用配置可直接使用校园节点。")
                Text("准备完成后，从仪表盘、“连接”菜单或菜单栏图标连接。断开时 FreeV6 会恢复网络。")
            }
            Section("自定义仪表盘") {
                Text("点“编辑布局”后可拖动卡片，或从卡片菜单前移、后移、调整宽度和移除。点“添加小组件”可以加回卡片或恢复默认布局，最后点“完成”保存。")
            }
            Section("配置与账户") {
                Text("在配置页编辑模式与规则，按 ⌘S 保存。重新载入会先询问是否放弃草稿，保存失败时会保留草稿。")
                Text("升级后，可在设置的 WARP 账户页检查已保存凭据。已导入的链式代理或备用配置也可以分别检查密钥。")
            }
            Section("窗口与快捷键") {
                LabeledContent("切换主窗口页面", value: "⌘1–⌘4")
                LabeledContent("打开设置", value: "⌘,")
                LabeledContent("保存代理规则", value: "⌘S")
                Text("关闭主窗口后，可从 Dock 或菜单栏重新打开。退出时 FreeV6 会处理未保存的草稿并等待网络恢复。")
            }
            Section("查看问题") {
                Text("按 ⌘4 打开日志，可筛选、暂停、导出或清空应用事件。在仪表盘遇到恢复失败时，可重试恢复或导出脱敏诊断。")
                Text("安装中断后的恢复与卸载入口位于设置的网络服务页。")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 420)
        .textSelection(.enabled)
            .focusedSceneValue(\.commandContext, .application)
    }
}
