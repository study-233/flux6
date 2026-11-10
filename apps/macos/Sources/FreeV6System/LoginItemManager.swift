import Foundation
import ServiceManagement

public enum LoginItemStatus: Sendable {
    case absent, nextLogin, enabled, needsApproval, moved

    public var description: String {
        switch self {
        case .absent: return "未安装登录项"
        case .nextLogin: return "已写入登录项，等待系统在下次登录时载入"
        case .enabled: return "系统已启用登录项"
        case .needsApproval: return "请在系统设置的“登录项”中允许 FreeV6"
        case .moved: return "登录项指向另一份 FreeV6，请重新登记"
        }
    }
}

public enum LoginItemError: LocalizedError {
    case location, conflict
    public var errorDescription: String? {
        switch self {
        case .location: return "请先把 FreeV6 拖到“应用程序”，再开启登录启动。"
        case .conflict: return "登录项文件与 FreeV6 的登记内容不符，请检查已有文件。"
        }
    }
}

/// The one-shot agent asks Launch Services to open the installed app. It never
/// owns the GUI process or starts a second copy when FreeV6 is already open.
public struct LoginItemManager: Sendable {
    static let label = "dev.freev6.desktop.login"
    private let folder: URL
    private let app: URL
    private let userApp: URL
    private let authorization: @Sendable (URL) -> SMAppService.Status

    public init() {
        self.init(home: FileManager.default.homeDirectoryForCurrentUser, app: Bundle.main.bundleURL)
    }
    package init(home: URL, app: URL, authorization: @escaping @Sendable (URL) -> SMAppService.Status = { SMAppService.statusForLegacyPlist(at: $0) }) {
        folder = home.appendingPathComponent("Library/LaunchAgents")
        userApp = home.appendingPathComponent("Applications/FreeV6.app")
        self.app = app.standardizedFileURL
        self.authorization = authorization
    }
    private var file: String { Self.label + ".plist" }
    private func permitted(_ path: String) -> Bool {
        path == "/Applications/FreeV6.app" || path == userApp.path
    }
    private func payload(for path: String) -> NSDictionary {
        ["Label": Self.label, "ProgramArguments": [path + "/Contents/Helpers/freev6-login-launcher"],
         "RunAtLoad": true, "LimitLoadToSessionType": "Aqua", "AssociatedBundleIdentifiers": ["dev.freev6.desktop"]]
    }
    private func registered(in folder: SecureDirectory) throws -> String? {
        guard let data = try folder.read(file, limit: 16_384) else { return nil }
        guard let spec = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
              let arguments = spec["ProgramArguments"] as? [String], arguments.count == 1 else { throw LoginItemError.conflict }
        let app = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        guard permitted(app), spec == payload(for: app) else { throw LoginItemError.conflict }
        return app
    }

    public func status() throws -> LoginItemStatus {
        var info = stat()
        if lstat(folder.path, &info) < 0, errno == ENOENT { return .absent }
        let directory = try SecureDirectory(path: folder.path, owner: geteuid())
        guard let path = try registered(in: directory) else { return .absent }
        guard path == app.path else { return .moved }
        switch authorization(folder.appendingPathComponent(file)) {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .nextLogin
        @unknown default: throw LoginItemError.conflict
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard permitted(app.path), app.resolvingSymlinksInPath().path == app.path else { throw LoginItemError.location }
        } else if try status() == .absent { return }
        let directory = try SecureDirectory(path: folder.path, owner: geteuid(), create: enabled)
        let old = try registered(in: directory)
        if enabled {
            if old == app.path { return }
            let bytes = try PropertyListSerialization.data(fromPropertyList: payload(for: app.path), format: .xml, options: 0)
            try directory.write(file, data: bytes, mode: 0o600)
        } else if old != nil {
            // The launcher exits after opening the app. Removing RunAtLoad is sufficient
            // to prevent the next login, and leaves the live app alone.
            try directory.remove(file)
        }
    }
}
