import Foundation

public enum DesktopPage: String, CaseIterable, Identifiable, Sendable {
    case overview, nodes, configuration, logs
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: return "概览"
        case .nodes: return "节点"
        case .configuration: return "配置"
        case .logs: return "日志"
        }
    }
    public var symbol: String {
        switch self {
        case .overview: return "network"
        case .nodes: return "point.3.connected.trianglepath.dotted"
        case .configuration: return "slider.horizontal.3"
        case .logs: return "text.alignleft"
        }
    }
}

public enum PreferencesPage: String, Sendable {
    case general, rules, account, core, service
}

public enum CommandContext: Equatable, Sendable {
    case application, main(DesktopPage), preferences(PreferencesPage)
    public var editsConfiguration: Bool {
        self == .main(.configuration) || self == .preferences(.rules)
    }
}

public enum DesktopCommand: Equatable, Sendable {
    case showMain, showPage(DesktopPage), showCore, configureService, refreshService
    case checkCore, downloadCore, cancelCoreDownload, saveConfiguration, reloadConfiguration
    case connect, importChain, refreshCloud, measureNodes, exportLogs, exportDiagnostics, checkUpdates
    case help, quit

    public var title: String {
        switch self {
        case .showMain: return "打开主窗口"
        case .showPage(let page): return page.title
        case .showCore: return "准备网络核心…"
        case .configureService: return "设置网络服务…"
        case .refreshService: return "刷新服务状态"
        case .checkCore: return "检查本地核心"
        case .downloadCore: return "下载核心"
        case .cancelCoreDownload: return "取消下载"
        case .saveConfiguration: return "保存配置"
        case .reloadConfiguration: return "重新载入配置…"
        case .connect: return "连接"
        case .importChain: return "导入链式代理配置…"
        case .refreshCloud: return "刷新备用配置"
        case .measureNodes: return "测量节点延迟"
        case .exportLogs: return "导出日志…"
        case .exportDiagnostics: return "导出脱敏诊断…"
        case .checkUpdates: return "检查更新…"
        case .help: return "FreeV6 使用说明"
        case .quit: return "退出 FreeV6"
        }
    }
    public var symbol: String {
        switch self {
        case .showMain: return "macwindow"
        case .showPage(let page): return page.symbol
        case .showCore, .downloadCore: return "arrow.down.circle"
        case .configureService: return "wrench.and.screwdriver"
        case .refreshService, .reloadConfiguration, .refreshCloud: return "arrow.clockwise"
        case .checkCore: return "checkmark.shield"
        case .cancelCoreDownload: return "xmark.circle"
        case .saveConfiguration: return "square.and.arrow.down"
        case .connect: return "power"
        case .importChain: return "square.and.arrow.down.on.square"
        case .measureNodes: return "speedometer"
        case .exportLogs, .exportDiagnostics: return "square.and.arrow.up"
        case .checkUpdates: return "arrow.triangle.2.circlepath"
        case .help: return "questionmark.circle"
        case .quit: return "rectangle.portrait.and.arrow.right"
        }
    }
}

public enum DesktopServiceState: Sendable {
    case checking, missing, ready, managing, needsRepair
    public var busy: Bool { self == .checking || self == .managing }
    public var title: String {
        switch self {
        case .checking: return "正在检查服务…"
        case .missing: return "需要设置网络服务"
        case .ready: return "连接功能待接入"
        case .managing: return "正在设置网络服务…"
        case .needsRepair: return "网络服务需要检查"
        }
    }
    public var symbol: String {
        switch self {
        case .checking, .managing: return "clock"
        case .missing, .needsRepair: return "exclamationmark.triangle"
        case .ready: return "network"
        }
    }
}

public struct CommandAvailability: Equatable, Sendable {
    public let enabled: Bool
    public let reason: String?
    public static let available = Self(enabled: true, reason: nil)
    public static func unavailable(_ reason: String) -> Self { Self(enabled: false, reason: reason) }
}

// This is the capability set actually implemented by the current app, not a
// simulated connection state. A service handshake does not authorize TUN UI.
public struct DesktopCommandState: Sendable {
    public var service: DesktopServiceState = .checking
    public var coreBusy = false
    public var coreAvailable = false
    public var coreCancelable = false
    public var settingsBusy = false
    public var settingsLoaded = false
    public var settingsChanged = false
    public var promptActive = false
    public var terminating = false
    public var credentialsBusy = false
    public var credentialsPending = false
    public init() {}

    public var primaryCommand: DesktopCommand {
        switch service {
        case .missing, .needsRepair: return .configureService
        case .ready where !coreAvailable: return .showCore
        default: return .connect
        }
    }

    public func availability(_ command: DesktopCommand, in context: CommandContext = .application) -> CommandAvailability {
        if terminating { return .unavailable("正在退出并回收业务进程…") }
        if promptActive { return .unavailable("请先处理当前确认窗口") }
        switch command {
        case .showMain, .showPage, .showCore, .help:
            return .available
        case .configureService, .refreshService:
            return service.busy ? .unavailable("请等待网络服务操作结束") : .available
        case .checkCore:
            return coreBusy ? .unavailable("核心准备正在进行") : .available
        case .downloadCore:
            if coreBusy { return .unavailable("核心准备正在进行") }
            return coreAvailable ? .unavailable("核心安装包已校验") : .available
        case .cancelCoreDownload:
            return coreCancelable ? .available : .unavailable("当前没有可取消的下载")
        case .saveConfiguration, .reloadConfiguration:
            guard context.editsConfiguration else { return .unavailable("请先打开代理规则编辑页") }
            guard !settingsBusy else { return .unavailable("配置读写正在进行") }
            if command == .saveConfiguration && (!settingsLoaded || !settingsChanged) {
                return .unavailable(settingsLoaded ? "没有未保存的更改" : "请先载入配置")
            }
            return .available
        case .quit:
            if credentialsBusy { return .unavailable("请等待凭据操作结束；系统授权可在弹窗中取消") }
            if credentialsPending { return .unavailable("新凭据尚未保存，请先保存或放弃本次注册结果") }
            return service.busy || settingsBusy ? .unavailable("请等待配置读写或网络服务操作结束") : .available
        case .connect:
            return .unavailable("真实网络连接与恢复功能尚未接入")
        case .importChain, .refreshCloud, .measureNodes, .exportLogs, .exportDiagnostics, .checkUpdates:
            return .unavailable("此功能将在后续开发阶段接入")
        }
    }
}
