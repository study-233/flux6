import SwiftUI
import FreeV6Business
import FreeV6Desktop
import FreeV6System

@MainActor final class BusinessSession {
    private let location: WorkerLocation?
    private var client: WorkerClient?

    init(location: WorkerLocation? = nil) { self.location = location }

    func worker() throws -> WorkerClient {
        if let client { return client }
        let client = WorkerClient(location: try location ?? WorkerLocation.application())
        self.client = client
        return client
    }
    func shutdown() async {
        let current = client
        client = nil
        await current?.shutdown()
    }
}

@MainActor final class BusinessModel: ObservableObject {
    @Published var snapshot: SettingsSnapshot?
    @Published var mode: ProxyMode = .rule
    @Published var campusText = "" { didSet { if ruleIssue?.field == .campus { ruleIssue = nil } } }
    @Published var blacklistText = "" { didSet { if ruleIssue?.field == .blacklist { ruleIssue = nil } } }
    @Published private(set) var ruleIssue: ProxyRuleIssue?
    @Published var devMode = false
    @Published var busy = false
    @Published var error: String?
    @Published var status = "正在连接业务组件…"
    private let session: BusinessSession
    init(session: BusinessSession) { self.session = session }

    @Published private(set) var notice: MaintainerNotice?
    @Published private(set) var checkingNotice = false
    @Published private(set) var noticeError: String?

    func refreshNotice() async {
        #if FREEV6_UI_FIXTURE
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let sample = #"""
        {"source":"cache","fetchedAt":"\#(timestamp)","cloudAllowed":true,"items":[
          {"id":"fixture-welcome","title":"仪表盘使用说明","published":"2026-11-05T00:00:00Z",
           "body":"点「编辑布局」选择需要的小组件，点「完成」保存布局。","level":"info"},
          {"id":"fixture-rules","title":"规则数据更新","published":"2026-11-04T00:00:00Z",
           "body":"可以在设置的核心与数据页检查本地规则数据。","level":"info"}
        ]}
        """#
        notice = try? JSONDecoder().decode(MaintainerNotice.self, from: Data(sample.utf8))
        #else
        guard !checkingNotice else { return }
        checkingNotice = true
        noticeError = nil
        defer { checkingNotice = false }
        do {
            let worker = try session.worker()
            notice = try await worker.maintainerNotice(refresh: false)
            notice = try await worker.maintainerNotice(refresh: true)
        } catch { noticeError = error.localizedDescription }
        #endif
    }

    var hasChanges: Bool {
        guard let snapshot else { return false }
        return draft != snapshot.settings
    }

    private var draft: ProxyPreferences? {
        guard var preferences = snapshot?.settings else { return nil }
        preferences.mode = mode
        preferences.campusCidrs = lines(campusText)
        preferences.blacklist = lines(blacklistText)
        preferences.devMode = devMode
        return preferences
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func reload() async {
        guard !busy else { return }
        busy = true; error = nil; ruleIssue = nil
        status = "正在读取配置…"
        defer { busy = false }
        do {
            let client = try session.worker()
            accept(try await client.settings())
            status = "配置已载入"
        } catch {
            self.error = error.localizedDescription
            status = "配置未载入"
        }
    }

    func save() async {
        guard !busy, let snapshot, let preferences = draft else { return }
        busy = true; error = nil; ruleIssue = nil
        status = "正在保存…"
        defer { busy = false }
        do {
            let client = try session.worker()
            accept(try await client.save(preferences, revision: snapshot.revision))
            status = "配置已保存"
        } catch {
            if let failure = error as? WorkerRemoteError, failure.code == -32602 {
                ruleIssue = ProxyRuleIssue.locate(in: campusText, field: .campus)
                    ?? ProxyRuleIssue.locate(in: blacklistText, field: .blacklist)
            }
            self.error = ruleIssue == nil ? error.localizedDescription : nil
            status = "代理规则尚未保存"
        }
    }

    /// Update just the stored default, then read the worker's current configuration.
    func saveConfirmedMode(_ value: ProxyMode, baseline: SettingsSnapshot) async throws {
        guard !busy, snapshot?.revision == baseline.revision else { throw WorkerClientError.staleConfiguration }
        busy = true
        defer { busy = false }
        let client = try session.worker()
        if baseline.settings.mode != value {
            var updated = baseline.settings
            updated.mode = value
            mergeSavedDefaults(try await client.save(updated, revision: baseline.revision))
        }
        guard try await refreshModeBaseline() == value else { throw WorkerClientError.staleConfiguration }
    }

    @discardableResult func refreshModeBaseline() async throws -> ProxyMode {
        let stored = try await session.worker().settings()
        mergeSavedDefaults(stored)
        return snapshot?.settings.mode ?? stored.settings.mode
    }

    /// A revision conflict may include other edits. Keep every field the editor has actually changed.
    private func mergeSavedDefaults(_ stored: SettingsSnapshot) {
        guard let previous = snapshot else { accept(stored); return }
        guard stored.revision >= previous.revision else { return }
        if mode == previous.settings.mode { mode = stored.settings.mode }
        if devMode == previous.settings.devMode { devMode = stored.settings.devMode }
        if lines(campusText) == previous.settings.campusCidrs, previous.settings.campusCidrs != stored.settings.campusCidrs {
            campusText = stored.settings.campusCidrs.joined(separator: "\n")
        }
        if lines(blacklistText) == previous.settings.blacklist, previous.settings.blacklist != stored.settings.blacklist {
            blacklistText = stored.settings.blacklist.joined(separator: "\n")
        }
        snapshot = stored
    }

    enum ChainChange { case load(ChainImportSource), enable(Bool), clear, checkKey }

    @Published private(set) var chainMessage: String?
    @Published private(set) var chainError: String?

    @discardableResult func changeChain(_ change: ChainChange) async -> String? {
        guard !busy, let baseline = snapshot else { return "请等待配置载入，再重试。" }
        #if FREEV6_UI_FIXTURE
        chainError = "模拟订阅导入超时。请检查地址后重试。"
        return chainError
        #else
        busy = true
        chainMessage = nil; chainError = nil
        defer { busy = false }
        do {
            let saved: SettingsSnapshot
            switch change {
            case .checkKey:
                guard baseline.chain != nil else { throw WorkerClientError.staleConfiguration }
                try await ChainProfileKey().checkAccess()
                chainMessage = "已确认可以读取链式代理密钥。"
                return nil
            case .load(let source):
                let key = try await ChainProfileKey().load(allowCreation: baseline.chain == nil)
                saved = try await session.worker().importChain(from: source, settings: baseline, key: key)
            case .enable(let enabled): saved = try await session.worker().setChainEnabled(enabled, settings: baseline)
            case .clear: saved = try await session.worker().clearChain(settings: baseline)
            }
            snapshot = saved // Proxy rule drafts belong to the editor and survive a profile change.
            chainMessage = saved.chain.map { $0.enabled ? "链式代理将在下次连接时使用。" : "链式代理已停用。" } ?? "已清除链式配置。"
        } catch { chainError = error.localizedDescription }
        return chainError
        #endif
    }

    enum CloudChange { case load(CloudImportSource), edit(CloudMutation), checkKey }
    @Published private(set) var cloudError: String?
    @Published private(set) var cloudMessage: String?
    // Both windows edit the same unsaved address. Keep it in memory until explicitly saved.
    @Published private var portalDraft: String?
    var portalAddress: String {
        get { portalDraft ?? snapshot?.portalHost ?? "" }
        set { portalDraft = newValue == (snapshot?.portalHost ?? "") ? nil : newValue }
    }
    var hasPortalChanges: Bool { portalAddress != (snapshot?.portalHost ?? "") }

    @discardableResult func savePortalAddress() async -> String? {
        guard hasPortalChanges else { return nil }
        return await changeCloud(.edit(.portal(portalAddress)))
    }

    var cloudOpen: Bool {
        guard let notice, notice.cloudAllowed, let stamp = notice.fetchedAt,
              let date = ISO8601DateFormatter().date(from: stamp) else { return false }
        return (0...7 * 24 * 3600).contains(-date.timeIntervalSinceNow)
    }
    var canFetchCloud: Bool { cloudOpen && snapshot?.chain?.enabled != true }
    var canRefreshCloud: Bool {
        guard canFetchCloud, let source = snapshot?.cloud?.source else { return false }
        return source == .url || (source == .portal && snapshot?.portalHost != nil)
    }

    @discardableResult func changeCloud(_ change: CloudChange) async -> String? {
        guard !busy, let baseline = snapshot else { return "请等待配置载入，再重试。" }
        #if FREEV6_UI_FIXTURE
        // Saving a portal address writes only the isolated worker's temporary preferences.
        // All other fixture operations return before they can fetch a source or read a key.
        guard case .edit(.portal) = change else {
            cloudError = "模拟备用配置获取超时。请检查来源后重试。"
            return cloudError
        }
        #endif
        busy = true; cloudError = nil; cloudMessage = nil
        defer { busy = false }
        do {
            switch change {
            case .checkKey:
                guard baseline.cloud != nil else { throw WorkerClientError.staleConfiguration }
                try await ChainProfileKey(storage: KeychainSecretStorage.cloudKey()).checkAccess()
                cloudMessage = "已确认可以读取备用配置密钥。"
            case .load(let source):
                guard canFetchCloud else { throw WorkerClientError.staleConfiguration }
                let key = try await ChainProfileKey(storage: KeychainSecretStorage.cloudKey()).load(allowCreation: baseline.cloud == nil)
                snapshot = try await session.worker().importCloud(from: source, settings: baseline, key: key)
                if case .portal(let address) = source, portalDraft == address { portalDraft = nil }
                cloudMessage = "已保存备用节点，下次连接时使用。"
            case .edit(let mutation):
                snapshot = try await session.worker().changeCloud(mutation, settings: baseline)
                switch mutation {
                case .enable(let value): cloudMessage = value ? "下次连接将使用备用配置。" : "备用配置已停用。"
                case .clear: cloudMessage = "已清除备用节点。"
                case .portal(let savedAddress):
                    if portalDraft == savedAddress { portalDraft = nil }
                    cloudMessage = "已保存校园登录页地址。"
                }
            }
        } catch { cloudError = error.localizedDescription }
        return cloudError
    }

    private func accept(_ snapshot: SettingsSnapshot) {
        self.snapshot = snapshot
        mode = snapshot.settings.mode
        campusText = snapshot.settings.campusCidrs.joined(separator: "\n")
        blacklistText = snapshot.settings.blacklist.joined(separator: "\n")
        devMode = snapshot.settings.devMode
    }
}

struct BusinessSettingsView: View {
    @ObservedObject var model: BusinessModel
    @ObservedObject var app: AppModel
    @State private var confirmDeveloperMode = false
    @State private var showCampus = false
    @State private var showBlacklist = false
    let context: CommandContext
    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: model.ruleIssue?.id, initial: true) { _, _ in
                    guard let issue = model.ruleIssue else { return }
                    if issue.field == .campus { showCampus = true } else { showBlacklist = true }
                    Task { @MainActor in proxy.scrollTo(issue.field, anchor: .center) }
                }
        }
    }

    private var form: some View {
        Form {
            Section("代理规则") {
                if let live = app.controls.state?.mode, app.network.phase == .running {
                    LabeledContent("当前会话", value: live.title + "模式")
                }
                LabeledContent("下次连接模式") {
                    ModeSegments(title: "下次连接模式", selection: CoreMode(rawValue: model.mode.rawValue)) { mode in
                        if let preference = ProxyMode(rawValue: mode.rawValue) { model.mode = preference }
                    }
                    .frame(maxWidth: 244)
                }
                Toggle("开发者模式", isOn: Binding(get: { model.devMode }, set: { enabled in
                    if enabled { confirmDeveloperMode = true } else { model.devMode = false }
                }))
                .confirmationDialog("开启开发者模式？", isPresented: $confirmDeveloperMode) {
                    Button("开启") { model.devMode = true }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("保存后，下次连接将跳过校园 IPv6 检测和域名黑名单。")
                }
                Text("⌘S 保存下次连接模式、开发者模式和域名与网段。")
                    .font(.callout).foregroundStyle(.secondary)
            }.disabled(model.busy || app.configurationBusy || model.snapshot == nil)
            Section("域名与网段") {
                rulesEditor(.campus, text: $model.campusText, expanded: $showCampus,
                            hint: "每行一个域名或 CIDR，例如 edu.cn 或 202.204.0.0/12。")
                rulesEditor(.blacklist, text: $model.blacklistText, expanded: $showBlacklist,
                            hint: "每行一个域名，留空表示不添加自定义黑名单。")
            }.disabled(model.busy || app.configurationBusy || model.snapshot == nil)
            ChainSettingsSection(model: model, app: app, context: context)
            CloudSettingsSection(model: model, app: app)
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.hasChanges ? "代理规则有未保存的更改" : model.status)
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    DesktopCommandButton(.reloadConfiguration, model: app, context: context)
                    DesktopCommandButton(.saveConfiguration, model: app, context: context)
                        .buttonStyle(.borderedProminent)
                }.padding(.horizontal, 14)
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 14)
                }
            }.padding(.bottom, 8).background(.bar)
        }
    }

    private func rulesEditor(_ field: ProxyRuleField, text: Binding<String>, expanded: Binding<Bool>,
                             hint: String) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            Text(hint).font(.callout).foregroundStyle(.secondary)
            let issue = model.ruleIssue.flatMap { $0.field == field ? $0 : nil }
            RuleTextEditor(text: text, field: field, issue: issue)
                .frame(height: 94)
            if let issue {
                Label(issue.message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    .font(.callout).textSelection(.enabled)
            }
        } label: {
            let count = text.wrappedValue.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            LabeledContent(field.title, value: "\(count) 条")
        }.id(field)
    }
}
