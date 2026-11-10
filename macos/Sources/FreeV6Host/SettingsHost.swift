import Combine
import Foundation
import FreeV6Business
import FreeV6Desktop
import FreeV6System

struct SettingsFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RuleForm {
    let baseline: SettingsSnapshot
    var mode: ProxyMode
    var campus: String
    var blacklist: String
    var devMode: Bool
    init(_ source: SettingsSnapshot) {
        baseline = source
        mode = source.settings.mode
        campus = source.settings.campusCidrs.joined(separator: "\n")
        blacklist = source.settings.blacklist.joined(separator: "\n")
        devMode = source.settings.devMode
    }
    private func entries(_ value: String) -> [String] {
        value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var settings: ProxyPreferences {
        var value = baseline.settings
        value.mode = mode; value.devMode = devMode
        value.campusCidrs = entries(campus); value.blacklist = entries(blacklist)
        return value
    }
    var dirty: Bool { settings != baseline.settings }
    func merged(with current: ProxyPreferences) throws -> ProxyPreferences {
        func resolve<T: Equatable>(_ original: T, _ edited: T, _ saved: T) throws -> T {
            if edited == original { return saved }
            guard saved == original || edited == saved else {
                throw SettingsFailure("另一窗口已修改同一项。请核对已保存的配置，或重新载入后再编辑。")
            }
            return edited
        }
        let original = baseline.settings, edit = settings
        var value = current
        value.mode = try resolve(original.mode, edit.mode, current.mode)
        value.devMode = try resolve(original.devMode, edit.devMode, current.devMode)
        value.campusCidrs = try resolve(original.campusCidrs, edit.campusCidrs, current.campusCidrs)
        value.blacklist = try resolve(original.blacklist, edit.blacklist, current.blacklist)
        return value
    }
    var map: [String: Any] {
        ["mode": mode.rawValue, "devMode": devMode, "campus": campus, "blacklist": blacklist,
         "revision": baseline.revision, "dirty": dirty]
    }
}

@MainActor final class HostSettings {
    let worker: WorkerClient, defaults: UserDefaults, logs: DesktopLogs
    let preview: Bool
    let startup: DesktopStartup
    let registration: WarpRegistration
    let chainKey: ChainProfileKey, cloudKey: ChainProfileKey
    var onChange: (() -> Void)?
    var onLogChange: (() -> Void)?
    let logPages: HostLogPages
    private var subscriptions = Set<AnyCancellable>()
    private var logEventQueued = false
    var stored: SettingsSnapshot?
    private var forms: [String: RuleForm] = [:]
    private var issues: [String: ProxyRuleIssue] = [:]
    var notice: MaintainerNotice?
    var noticeError: String?
    var layout: DashboardLayout
    var layoutDraft: DashboardLayout?
    private var resetLayout = false
    private var layoutDirty: Bool { layoutDraft.map { $0 != layout || (resetLayout && defaults.data(forKey: "dashboardLayout") != nil) } ?? false }
    var account: WarpAccountSummary?
    var pendingCredential = false
    var accountStatus = "连接时自动读取凭据，缺失时自动注册"
    var coreStatus = "尚未检查网络核心"
    var geodataStatus = "尚未检查规则数据"
    var coreReady = false, geodataReady = false
    var isolatedAccount = false
    var preparationTask: Task<Void, Never>?
    var preparationID: UUID?
    var preparationName: String?
    var preparationCanCancel = false
    var preparationProgress = ""
    var progressSequence: UInt64 = 0
    var busy = false
    var initializationError: String?
    var setupCompleted: Bool {
        get { defaults.bool(forKey: "firstSetupCompleted") }
        set { defaults.set(newValue, forKey: "firstSetupCompleted") }
    }
    var accepted: Bool { startup.accepted }
    var blockedForConnection: Bool { busy || pendingCredential || forms.values.contains(where: \.dirty) }
    var hasUnsavedRules: Bool { forms.values.contains(where: \.dirty) }

    init(worker: WorkerClient, defaults: UserDefaults, logs: DesktopLogs, preview: Bool,
         noticesDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Notices"),
         profileKeys: (chain: ChainProfileKey, cloud: ChainProfileKey)? = nil, registration: WarpRegistration? = nil) {
        self.worker = worker; self.defaults = defaults; self.logs = logs; self.preview = preview
        logPages = HostLogPages(logs)
        chainKey = profileKeys?.chain ?? ChainProfileKey(storage: preview ? KeychainSecretStorage.integrationProfileKey(chain: true) : KeychainSecretStorage.chainKey())
        cloudKey = profileKeys?.cloud ?? ChainProfileKey(storage: preview ? KeychainSecretStorage.integrationProfileKey(chain: false) : KeychainSecretStorage.cloudKey())
        let notices = noticesDirectory.flatMap { try? StartupNotices(directory: $0) }
        startup = DesktopStartup(defaults: defaults, notices: notices)
        layout = DashboardLayout(data: defaults.data(forKey: "dashboardLayout"))
        self.registration = registration ?? WarpRegistration(vault: WarpCredentialVault()) { name, progress in
            try await worker.registerWarp(name: name, progress: progress)
        }
        logs.objectWillChange.sink { [weak self] in
            guard let self, !self.logEventQueued else { return }
            self.logEventQueued = true
            Task { @MainActor [weak self] in
                self?.logEventQueued = false
                self?.onLogChange?()
            }
        }.store(in: &subscriptions)
    }

    func load() async {
        guard accepted else { return }
        do { refreshStored(try await worker.settings()); initializationError = nil }
        catch { initializationError = error.localizedDescription }
        try? await performPreparation("preparation.inspectResources", device: "", progress: { _ in }, willSave: {})
        if !preview { await startup.refreshLogin() }
        do { try await refreshNotice(online: false) } catch { noticeError = error.localizedDescription }
    }

    func refreshStored(_ value: SettingsSnapshot) {
        guard stored.map({ value.revision >= $0.revision }) ?? true else { return }
        stored = value
    }

    func snapshot() -> [String: Any] {
        var rules: [String: Any] = [:], drafts: [String: Bool] = [:]
        for window in ["main", "settings"] {
            var page = (forms[window] ?? stored.map(RuleForm.init))?.map ?? [:]
            if let issue = issues[window] {
                page["issue"] = ["field": issue.field == .campus ? "campus" : "blacklist", "line": issue.line,
                                 "start": issue.range.location, "length": issue.range.length, "message": issue.message] as [String: Any]
            }
            rules[window] = page
            drafts[window] = forms[window]?.dirty == true || (window == "main" && layoutDirty)
        }
        return ["accepted": accepted, "busy": busy, "setupCompleted": setupCompleted, "error": initializationError ?? "",
                "onboarding": ["agreement": accepted ? "" : startup.notices?.agreement ?? "", "privacy": accepted ? "" : startup.notices?.privacy ?? "",
                               "approvalAvailable": startup.notices != nil] as [String: Any],
                "rules": rules, "drafts": drafts, "profiles": profileMap, "logs": logPages.metadata(), "notices": noticeMap,
                "layout": tiles(layout), "layoutCustom": defaults.data(forKey: "dashboardLayout") != nil,
                "layoutEditor": tiles(layoutDraft ?? layout), "preferences": preferencesMap, "preparation": preparationMap,
                "update": ["available": !preview, "status": preview ? "隔离验收包使用独立构建，不安装发行更新。" : "通过签名更新通道检查新版本。"] as [String: Any]]
    }

    private func tiles(_ value: DashboardLayout) -> [[String: String]] {
        value.tiles.map { ["kind": $0.kind.rawValue, "size": $0.size.rawValue] }
    }

    func handle(_ name: String, arguments a: [String: Any]) async throws -> Bool {
        let window = (a["window"] as? String) == "settings" ? "settings" : "main"
        if name == "preparation.accept" {
            guard startup.notices != nil else { throw SettingsFailure("无法读取随应用提供的协议与隐私政策。") }
            startup.acceptNotices(); await load(); return true
        }
        let category = name.split(separator: ".").first.map(String.init) ?? ""
        guard ["rules","profile","logs","layout","notices","preferences","preparation","draft"].contains(category) else { return false }
        guard accepted else { throw SettingsFailure("请先阅读用户协议和隐私政策。") }
        defer { onChange?() }
        switch name {
        case "rules.edit": try editRules(a, window: window)
        case "rules.reload":
            let value = try await worker.settings()
            refreshStored(value); initializationError = nil; forms[window] = nil; issues[window] = nil
        case "rules.save", "draft.saveAll":
            try await saveRules(window)
            if name == "draft.saveAll", window == "main", layoutDraft != nil { try saveLayout() }
        case "draft.discardAll":
            forms[window] = nil; issues[window] = nil
            if window == "main" { layoutDraft = nil; resetLayout = false }
        case "layout.edit": try editLayout(a)
        case "logs.filter":
            guard let level = a["level"] as? String, level == "全部" || EventLevel(rawValue: level) != nil else { throw SettingsFailure("无效的日志级别。") }
            logs.level = EventLevel(rawValue: level)
        case "logs.pause":
            if (a["paused"] as? Bool) != (logs.paused != nil) { logs.togglePause() }
        case "logs.clear":
            logs.clear(); await logs.finishWrites()
            if let error = logs.clearError { throw SettingsFailure(error) }
        case "notices.refresh": try await refreshNotice(online: true)
        case "notices.read": try markNotice(a)
        case "preferences.set": try await changePreference(a)
        default:
            if category == "profile" { try await modifyProfile(name, a) }
            else if category == "preparation" { try await prepare(name, arguments: a) }
            else { return false }
        }
        return true
    }

    private func editRules(_ a: [String: Any], window: String) throws {
        guard let source = stored, let field = a["field"] as? String else { throw SettingsFailure("请先载入配置。") }
        var draft = forms[window] ?? RuleForm(source)
        switch field {
        case "campus", "blacklist":
            guard let text = a["value"] as? String, text.utf8.count <= 256 * 1024 else { throw SettingsFailure("规则文本过长。") }
            if field == "campus" { draft.campus = text } else { draft.blacklist = text }
        case "mode":
            guard let mode = (a["value"] as? String).flatMap(ProxyMode.init(rawValue:)) else { throw SettingsFailure("请选择有效模式。") }; draft.mode = mode
        case "devMode":
            guard let enabled = a["value"] as? Bool else { throw SettingsFailure("无效的开发者模式。") }; draft.devMode = enabled
        default: throw SettingsFailure("无效的配置编辑项。")
        }
        forms[window] = draft; issues[window] = nil
    }

    private func saveRules(_ window: String) async throws {
        guard let draft = forms[window] else { return }
        guard draft.dirty else { forms[window] = nil; return }
        guard !busy else { throw SettingsFailure("请等待当前操作完成。") }
        busy = true; defer { busy = false }
        do {
            let latest = try await worker.settings()
            let value = try draft.merged(with: latest.settings)
            let saved = try await worker.save(value, revision: latest.revision)
            refreshStored(saved); issues[window] = nil; forms[window] = nil
            logs.record(.settingsChanged)
        } catch {
            if let failure = error as? WorkerRemoteError, failure.code == -32602 {
                issues[window] = ProxyRuleIssue.locate(in: draft.campus, field: .campus) ?? ProxyRuleIssue.locate(in: draft.blacklist, field: .blacklist)
            }
            logs.record(.settingsFailure)
            throw SettingsFailure(issues[window]?.message ?? error.localizedDescription)
        }
    }

    private func editLayout(_ args: [String: Any]) throws {
        let op = args["op"] as? String
        if op == "begin" { if layoutDraft == nil { layoutDraft = layout }; return }
        if op == "discard" { layoutDraft = nil; resetLayout = false; return }
        guard var draft = layoutDraft else { throw SettingsFailure("先打开布局编辑。") }
        if op == "save" { try saveLayout(); return }
        if op == "reset" { layoutDraft = DashboardLayout(); resetLayout = true; return }
        guard let kind = (args["kind"] as? String).flatMap(DashboardWidget.init(rawValue:)) else { throw SettingsFailure("无效的小组件。") }
        switch op {
        case "add": draft.add(kind)
        case "remove": draft.remove(kind)
        case "resize":
            guard let size = (args["size"] as? String).flatMap(DashboardSize.init(rawValue:)) else { throw SettingsFailure("无效的卡片宽度。") }
            draft.resize(kind, to: size)
        case "move":
            let before = args["before"] as? String
            if let before, DashboardWidget(rawValue: before) == nil { throw SettingsFailure("目标小组件已不存在。") }
            draft.move([kind], before: before.flatMap(DashboardWidget.init(rawValue:)))
        default: throw SettingsFailure("无效的布局操作。")
        }
        if draft != layoutDraft { resetLayout = false }; layoutDraft = draft
    }

    private func saveLayout() throws {
        guard let draft = layoutDraft else { return }
        if resetLayout { defaults.removeObject(forKey: "dashboardLayout"); layout = DashboardLayout() }
        else if draft != layout { defaults.set(try draft.encoded(), forKey: "dashboardLayout"); layout = draft }
        resetLayout = false; layoutDraft = nil
    }
}
