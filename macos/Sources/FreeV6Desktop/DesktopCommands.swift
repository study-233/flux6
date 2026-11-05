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
    case prepareConfiguration
    case connect, disconnect, retryRecovery, reviewSetup, importChain, refreshCloud, measureNodes, exportLogs, exportDiagnostics, checkUpdates
    case help, quit

    public var title: String {
        switch self {
        case .showMain: return "打开主窗口"
        case .showPage(let page): return page.title
        case .showCore: return "准备网络核心…"
        case .configureService: return "设置网络服务…"
        case .refreshService: return "刷新服务状态"
        case .checkCore: return "检查本地核心"
        case .prepareConfiguration: return "检查连接配置"
        case .downloadCore: return "下载核心"
        case .cancelCoreDownload: return "取消下载"
        case .saveConfiguration: return "保存配置"
        case .reloadConfiguration: return "重新载入配置…"
        case .connect: return "连接"
        case .disconnect: return "断开"
        case .retryRecovery: return "重试恢复网络"
        case .reviewSetup: return "查看连接准备…"
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
        case .prepareConfiguration: return "doc.text"
        case .cancelCoreDownload: return "xmark.circle"
        case .saveConfiguration: return "square.and.arrow.down"
        case .connect, .disconnect: return "power"
        case .retryRecovery: return "arrow.counterclockwise"
        case .reviewSetup: return "checklist"
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
        case .ready: return "网络服务已就绪"
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
    public var noticesAccepted = true
    public var service: DesktopServiceState = .checking
    public var network = DesktopNetworkPhase.unknown
    public var canTargetSession = false
    public var canMeasureNodes = false
    public var coreBusy = false
    public var coreAvailable = false
    public var coreCancelable = false
    public var settingsBusy = false
    public var cloudEnabled = false
    public var cloudRefreshAvailable = false
    public var settingsLoaded = false
    public var settingsChanged = false
    public var promptActive = false
    public var terminating = false
    public var hasVisibleLogs = false
    public var updateBusy = false
    public var updatePreparing = false
    public var credentialsBusy = false
    public var credentialsPending = false
    public var configurationReady = false
    public var configurationBusy = false
    public init() {}

    public var profileEditingAvailable: Bool {
        settingsLoaded && !settingsBusy && !configurationBusy && !terminating && !promptActive && !network.busy
    }

    public var primaryCommand: DesktopCommand {
        switch network {
        case .running, .disconnecting: return .disconnect
        case .recovering where canTargetSession: return .retryRecovery
        case .occupied, .recovering: return .refreshService
        default: break
        }
        switch service {
        case .missing, .needsRepair: return .configureService
        case .ready where network == .unknown: return .refreshService
        case .ready where network == .connecting: return .connect
        case .ready where !coreAvailable: return .showCore
        case .ready where !configurationReady: return .reviewSetup
        default: return .connect
        }
    }

    public func availability(_ command: DesktopCommand, in context: CommandContext = .application) -> CommandAvailability {
        if !noticesAccepted {
            switch command {
            case .showMain, .help, .quit, .disconnect, .retryRecovery, .refreshService: break
            default: return .unavailable("请先在主窗口阅读并同意用户协议与隐私政策")
            }
        }
        if terminating { return .unavailable("正在退出并回收业务进程…") }
        if promptActive { return .unavailable("请先处理当前确认窗口") }
        if updatePreparing {
            switch command {
            case .showMain, .showPage, .help, .exportLogs, .exportDiagnostics: break
            default: return .unavailable("正在恢复网络并准备应用升级")
            }
        }
        if network.busy {
            switch command {
            case .showMain, .showPage, .help, .exportLogs, .exportDiagnostics: break
            default: return .unavailable(network.title)
            }
        }
        if configurationBusy {
            switch command {
            case .configureService, .refreshService, .checkCore, .downloadCore, .prepareConfiguration,
                 .saveConfiguration, .reloadConfiguration, .connect, .quit:
                return .unavailable("连接配置检查正在进行，请等待完成")
            default: break
            }
        }
        switch command {
        case .showMain, .showPage, .showCore, .reviewSetup, .help:
            return .available
        case .configureService where service == .ready && network != .idle:
            return .unavailable("请先确认网络会话已停止")
        case .configureService, .refreshService:
            return service.busy ? .unavailable("请等待网络服务操作结束") : .available
        case .checkCore:
            return coreBusy ? .unavailable("核心准备正在进行") : .available
        case .downloadCore:
            if coreBusy { return .unavailable("核心准备正在进行") }
            return coreAvailable ? .unavailable("核心安装包已校验") : .available
        case .cancelCoreDownload:
            return coreCancelable ? .available : .unavailable("当前没有可取消的下载")
        case .prepareConfiguration:
            return configurationReady && !credentialsBusy && !settingsBusy && !credentialsPending
                ? .available : .unavailable("请先保存设置并准备凭据、核心和规则数据")
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
            return service == .ready && network == .idle && coreAvailable && configurationReady
                ? .available : .unavailable("请先确认会话空闲并完成连接准备")
        case .disconnect:
            return service == .ready && network == .running && canTargetSession
                ? .available : .unavailable("请先确认本人的运行会话")
        case .retryRecovery:
            return service == .ready && network == .recovering && canTargetSession
                ? .available : .unavailable("服务正在检查恢复记录")
        case .measureNodes:
            return network == .running && canMeasureNodes ? .available : .unavailable("请先连接并载入节点列表")
        case .importChain:
            guard !cloudEnabled else { return .unavailable("请先停用备用配置，以便导入链式代理") }
            return profileEditingAvailable ? .available : .unavailable("请先载入配置并等待当前操作结束")
        case .refreshCloud:
            guard cloudRefreshAvailable else { return .unavailable("请先确认公告开放，并获取可刷新的备用配置") }
            return profileEditingAvailable ? .available : .unavailable("请先载入配置并等待当前操作结束")
        case .exportLogs:
            return context == .main(.logs) && hasVisibleLogs ? .available : .unavailable("请打开日志页并选择有记录的级别")
        case .exportDiagnostics: return .available
        case .checkUpdates:
            return updateBusy ? .unavailable("更新检查正在进行") : .available
        }
    }
}
