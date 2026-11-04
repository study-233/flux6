import AppKit
import SwiftUI
import FreeV6Desktop

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
        }
        CommandMenu("连接") {
            DesktopCommandButton(.connect, model: model).keyboardShortcut("k", modifiers: [.command, .shift])
            Text(model.serviceState.title)
            Divider()
            DesktopCommandButton(.showPage(.configuration), model: model)
            DesktopCommandButton(.measureNodes, model: model)
            DesktopCommandButton(.refreshCloud, model: model)
            Divider()
            DesktopCommandButton(.configureService, model: model)
            DesktopCommandButton(.refreshService, model: model)
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
            case .configuration:
                DesktopCommandButton(.reloadConfiguration, model: model, context: .main(.configuration))
                DesktopCommandButton(.saveConfiguration, model: model, context: .main(.configuration))
            case .nodes:
                DesktopCommandButton(.measureNodes, model: model, context: .main(.nodes))
            case .logs:
                DesktopCommandButton(.exportLogs, model: model, context: .main(.logs))
            }
        }
        ToolbarItem(placement: .status) {
            Label(model.serviceState.title, systemImage: model.serviceState.symbol)
                .foregroundStyle(.secondary).lineLimit(1)
                .help(model.serviceStatus)
                .accessibilityLabel(model.serviceState.title)
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
        Text(model.serviceState.title)
        Text(model.core.status)
        Text(model.geodata.status)
        Text(model.warp.status)
        if let preferences = model.business.snapshot?.settings {
            Text("已保存配置：\(preferences.mode.title)")
        }
        Divider()
        DesktopCommandButton(model.commandState.primaryCommand, model: model)
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
                Text("当前开发版可以编辑代理规则、准备核心安装包，以及检查和设置网络服务。真实代理连接仍在开发中；核心下载或服务就绪不表示已经开启代理。")
                Text("开始使用").font(.headline)
                Text("将 FreeV6 拖入“应用程序”后，从概览页设置网络服务。核心可以在概览页或设置的“核心”页下载；下载完成后会自动校验。")
                Text("编辑配置").font(.headline)
                Text("在“配置”页编辑模式与规则，用 ⌘S 保存。重新载入会先询问是否放弃草稿；保存失败时保留草稿和错误信息。")
                Text("窗口与后台").font(.headline)
                Text("⌘1–⌘4 切换页面，⌘, 打开设置。关闭主窗口会保留后台入口；从 Dock 或右上角 FreeV6 菜单可以重新打开。⌘Q 退出时处理未保存草稿，并停止下载和业务进程。")
                Text("服务需要处理时").font(.headline)
                Text("先在概览页刷新状态并查看提示。安装中断后的恢复与卸载入口位于设置的“网络服务”页。授权请在 macOS 系统窗口中完成。")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.frame(minWidth: 460, idealWidth: 560, minHeight: 420)
            .textSelection(.enabled)
            .focusedSceneValue(\.commandContext, .application)
    }
}
