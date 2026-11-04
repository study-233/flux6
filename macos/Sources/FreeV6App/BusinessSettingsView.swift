import SwiftUI
import FreeV6Business

@MainActor final class BusinessModel: ObservableObject {
    @Published var snapshot: SettingsSnapshot?
    @Published var mode: ProxyMode = .rule
    @Published var campusText = ""
    @Published var blacklistText = ""
    @Published var devMode = false
    @Published var busy = false
    @Published var error: String?
    @Published var status = "正在连接业务组件…"
    private var client: WorkerClient?

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
            if client == nil { client = WorkerClient(location: try WorkerLocation.application()) }
            guard let client else { throw WorkerClientError.notAvailable }
            accept(try await client.settings())
            status = "配置已载入"
        } catch {
            self.error = error.localizedDescription
            status = "配置未载入"
        }
    }

    func save() async {
        guard !busy, let snapshot, let preferences = draft, let client else { return }
        busy = true; error = nil
        status = "正在保存…"
        defer { busy = false }
        do {
            accept(try await client.save(preferences, revision: snapshot.revision))
            status = "配置已保存"
        } catch {
            self.error = error.localizedDescription
            status = "保存未确认"
        }
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
    @State private var confirmReload = false
    var body: some View {
        Form {
            Section("代理规则") {
                Picker("工作模式", selection: $model.mode) {
                    ForEach(ProxyMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                Toggle("开发者模式", isOn: $model.devMode)
                Text("保存的配置用于后续连接。当前版本尚未开放 TUN 连接。")
                    .font(.callout).foregroundStyle(.secondary)
            }.disabled(model.busy || model.snapshot == nil)
            Section("校园白名单") {
                Text("每行一个域名或 CIDR，例如 edu.cn 或 202.204.0.0/12。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.campusText).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100).accessibilityLabel("校园白名单")
            }.disabled(model.busy || model.snapshot == nil)
            Section("黑名单") {
                Text("每行一个域名，留空表示不添加自定义黑名单。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.blacklistText).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100).accessibilityLabel("自定义黑名单")
            }.disabled(model.busy || model.snapshot == nil)
            Section {
                HStack {
                    Button("保存配置") { Task { await model.save() } }
                        .disabled(model.busy || !model.hasChanges)
                    Button("重新载入") {
                        if model.hasChanges { confirmReload = true }
                        else { Task { await model.reload() } }
                    }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.hasChanges ? "有未保存的更改" : model.status).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("放弃未保存的更改并重新载入？", isPresented: $confirmReload) {
            Button("重新载入", role: .destructive) { Task { await model.reload() } }
        }
    }
}
