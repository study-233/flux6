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
            DesktopCommandButton(.importChain, model: model).keyboardShortcut("o")
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
        ToolbarItemGroup(placement: .automatic) {
            switch model.page ?? .overview {
            case .overview:
                DesktopCommandButton(.refreshService, model: model)
                DesktopCommandButton(.prepareConfiguration, model: model)
            case .configuration:
                DesktopCommandButton(.reloadConfiguration, model: model, context: .main(.configuration))
                DesktopCommandButton(.saveConfiguration, model: model, context: .main(.configuration))
            case .nodes:
                DesktopCommandButton(.measureNodes, model: model, context: .main(.nodes))
            case .logs:
                LogLevelPicker(logs: model.logs).pickerStyle(.menu)
                LogActions(logs: model.logs)
                DesktopCommandButton(.exportLogs, model: model, context: .main(.logs))
            }
        }
        ToolbarItem(placement: .status) {
            Label(model.connectionTitle, systemImage: model.connectionSymbol)
                .foregroundStyle(.secondary).lineLimit(1)
                .help(model.network.statusError ?? model.network.error ?? model.connectionTitle)
                .accessibilityLabel(model.connectionTitle)
        }
        ToolbarItem(placement: .primaryAction) {
            DesktopCommandButton(model.commandState.primaryCommand, model: model)
                .labelStyle(.titleAndIcon)
        }
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
        } else {
            Text(model.core.status)
            Text(model.warp.status)
        }
        Divider()
        DesktopCommandButton(model.commandState.primaryCommand, model: model)
        RuntimeMenus(model: model).disabled(!model.startup.accepted)
        DesktopCommandButton(.showPage(.configuration), model: model)
        Menu("网络核心") {
            DesktopCommandButton(.downloadCore, model: model)
            DesktopCommandButton(.checkCore, model: model)
            DesktopCommandButton(.cancelCoreDownload, model: model)
        }
        Divider()
        DesktopCommandButton(.showMain, model: model)
        NativeSettingsLink().disabled(model.terminating || model.promptActive)
        DesktopCommandButton(.help, model: model)
        Divider()
        DesktopCommandButton(.quit, model: model)
    }
}

private struct NativeSettingsLink: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("设置…") }
        } else {
            Button("设置…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

struct NativeHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("FreeV6 使用说明").font(.title.bold())
                Text("从概览页准备网络服务、网络核心与规则数据。默认出口和链式代理需要 WARP 凭据，已启用的校园备用配置可直接使用校园节点。准备完成后可从工具栏、“连接”菜单或右上角的 FreeV6 图标连接或断开。")
                Text("开始使用").font(.headline)
                Text("将 FreeV6 拖入“应用程序”后，从概览页设置网络服务。核心可以在概览页或设置的“核心”页下载；下载完成后会自动校验。")
                Text("编辑配置").font(.headline)
                Text("在“配置”页编辑模式与规则，用 ⌘S 保存。重新载入会先询问是否放弃草稿；保存失败时保留草稿和错误信息。")
                Text("升级后读取已保存的密钥").font(.headline)
                Text("在概览中点击“检查已保存凭据”。已导入的链式代理或备用配置可在配置页检查各自的密钥。若钥匙串请求授权，请核对应用和条目名称，再决定是否允许。取消后可以重试。")
                Text("窗口与后台").font(.headline)
                Text("⌘1–⌘4 切换页面，⌘, 打开设置。关闭主窗口会保留后台入口；从 Dock 或右上角 FreeV6 菜单可以重新打开。⌘Q 退出时处理未保存草稿，等待服务恢复网络，再停止下载和业务进程。")
                Text("服务需要处理时").font(.headline)
                Text("先在概览页刷新状态并查看提示。按 ⌘4 查看最近事件，可选择级别并暂停显示。从“文件”菜单导出当前日志或含组件状态的脱敏诊断。安装中断后的恢复与卸载入口位于设置的“网络服务”页。")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.frame(minWidth: 460, idealWidth: 560, minHeight: 420)
            .textSelection(.enabled)
            .focusedSceneValue(\.commandContext, .application)
    }
}
