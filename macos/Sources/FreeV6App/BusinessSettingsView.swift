import SwiftUI
import FreeV6Business
import FreeV6Desktop

@MainActor final class BusinessSession {
    private var client: WorkerClient?
    func worker() throws -> WorkerClient {
        if let client { return client }
        let client = WorkerClient(location: try WorkerLocation.application())
        self.client = client
        return client
    }
    func shutdown() async { await client?.shutdown() }
}

@MainActor final class BusinessModel: ObservableObject {
    @Published var snapshot: SettingsSnapshot?
    @Published var mode: ProxyMode = .rule
    @Published var campusText = ""
    @Published var blacklistText = ""
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
        guard !checkingNotice else { return }
        checkingNotice = true
        noticeError = nil
        defer { checkingNotice = false }
        do {
            let worker = try session.worker()
            notice = try await worker.maintainerNotice(refresh: false)
            notice = try await worker.maintainerNotice(refresh: true)
        } catch { noticeError = error.localizedDescription }
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
        busy = true; error = nil
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
        busy = true; error = nil
        status = "正在保存…"
        defer { busy = false }
        do {
            let client = try session.worker()
            accept(try await client.save(preferences, revision: snapshot.revision))
            status = "配置已保存"
        } catch {
            self.error = error.localizedDescription
            status = "保存未确认"
        }
    }

    /// Save only the live mode against the observed worker revision. Preserve
    /// unsaved fields (including a separately edited default mode) in the UI.
    func saveConfirmedMode(_ value: ProxyMode, baseline: SettingsSnapshot) async throws {
        guard !busy, snapshot?.revision == baseline.revision else { throw WorkerClientError.staleConfiguration }
        guard baseline.settings.mode != value else { return }
        let preserveDraftMode = mode != baseline.settings.mode
        busy = true
        defer { busy = false }
        var updated = baseline.settings
        updated.mode = value
        let saved = try await session.worker().save(updated, revision: baseline.revision)
        snapshot = saved
        if !preserveDraftMode { mode = saved.settings.mode }
    }

    enum ChainChange { case load(ChainImportSource), enable(Bool), clear }

    @Published private(set) var chainMessage: String?
    @Published private(set) var chainError: String?

    func changeChain(_ change: ChainChange) async {
        guard !busy, let baseline = snapshot else { return }
        busy = true
        chainMessage = nil; chainError = nil
        defer { busy = false }
        do {
            let worker = try session.worker()
            let saved: SettingsSnapshot
            switch change {
            case .load(let source):
                let key = try await ChainProfileKey().load(allowCreation: baseline.chain == nil)
                saved = try await worker.importChain(from: source, settings: baseline, key: key)
            case .enable(let enabled): saved = try await worker.setChainEnabled(enabled, settings: baseline)
            case .clear: saved = try await worker.clearChain(settings: baseline)
            }
            snapshot = saved // Proxy rule drafts belong to the editor and survive a profile change.
            chainMessage = saved.chain.map { $0.enabled ? "链式代理将在下次连接时使用。" : "链式代理已停用。" } ?? "已清除链式配置。"
        } catch { chainError = error.localizedDescription }
    }

    enum CloudChange { case load(CloudImportSource), edit(CloudMutation) }
    @Published private(set) var cloudError: String?
    @Published private(set) var cloudMessage: String?
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

    func changeCloud(_ change: CloudChange) async {
        guard !busy, let baseline = snapshot else { return }
        busy = true; cloudError = nil; cloudMessage = nil
        defer { busy = false }
        do {
            let worker = try session.worker()
            switch change {
            case .load(let source):
                guard canFetchCloud else { throw WorkerClientError.staleConfiguration }
                let key = try await ChainProfileKey(storage: KeychainSecretStorage.cloudKey()).load(allowCreation: baseline.cloud == nil)
                snapshot = try await worker.importCloud(from: source, settings: baseline, key: key)
                cloudMessage = "已保存备用节点，下次连接时使用。"
            case .edit(let mutation):
                snapshot = try await worker.changeCloud(mutation, settings: baseline)
                switch mutation {
                case .enable(let value): cloudMessage = value ? "下次连接将使用备用配置。" : "备用配置已停用。"
                case .clear: cloudMessage = "已清除备用节点。"
                case .portal: cloudMessage = "已保存校园登录页地址。"
                }
            }
        } catch { cloudError = error.localizedDescription }
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
    let context: CommandContext
    var body: some View {
        Form {
            Section("代理规则") {
                Picker("工作模式", selection: $model.mode) {
                    ForEach(ProxyMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
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
                Text("保存的配置在下次连接时生效。")
                    .font(.callout).foregroundStyle(.secondary)
            }.disabled(model.busy || app.configurationBusy || model.snapshot == nil)
            ChainSettingsSection(model: model, app: app)
            CloudSettingsSection(model: model, app: app)

            Section("校园白名单") {
                Text("每行一个域名或 CIDR，例如 edu.cn 或 202.204.0.0/12。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.campusText).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100).accessibilityLabel("校园白名单")
            }.disabled(model.busy || app.configurationBusy || model.snapshot == nil)
            Section("黑名单") {
                Text("每行一个域名，留空表示不添加自定义黑名单。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.blacklistText).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100).accessibilityLabel("自定义黑名单")
            }.disabled(model.busy || app.configurationBusy || model.snapshot == nil)
            Section {
                HStack {
                    DesktopCommandButton(.saveConfiguration, model: app, context: context)
                    DesktopCommandButton(.reloadConfiguration, model: app, context: context)
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.hasChanges ? "有未保存的更改" : model.status).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }
}
