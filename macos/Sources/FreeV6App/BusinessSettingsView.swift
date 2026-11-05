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
