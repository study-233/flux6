import SwiftUI
import FreeV6Business

@MainActor final class WarpModel: ObservableObject {
    @Published var name = "freev6-macos"
    @Published private(set) var summary: WarpAccountSummary?
    @Published private(set) var inspected = false
    @Published private(set) var busy = false
    @Published private(set) var hasPending = false
    @Published private(set) var canCancel = false
    @Published private(set) var status = "尚未检查 WARP 凭据"
    @Published private(set) var error: String?
    private let workflow: WarpRegistration
    private let session: BusinessSession
    private var task: Task<Void, Never>?
    private var operation: UUID?
    private var lastProgress: UInt64 = 0
    private var acceptsProgress = false

    init(session: BusinessSession) {
        self.session = session
        workflow = WarpRegistration(vault: WarpCredentialVault()) { name, progress in
            try await session.worker().registerWarp(name: name, progress: progress)
        }
    }

    func withPreparedConfiguration<T: Sendable>(settings: SettingsSnapshot, runtimeId: String, geodataId: String, interactionAllowed: Bool = true,
                                                perform: @escaping @Sendable (PreparedConfiguration) async throws -> T) async throws -> T {
        guard !busy, !hasPending, let revision = summary?.revision else { throw RegistrationWorkflowError.busy }
        busy = true; error = nil; status = "正在读取连接所需凭据…"
        defer { busy = false }
        do {
            let worker = try session.worker()
            let chainKey = settings.chain?.enabled == true ? try await ChainProfileKey().load(allowCreation: false, interactionAllowed: interactionAllowed) : nil
            let result = try await workflow.withSavedTunnel(revision: revision, interactionAllowed: interactionAllowed) { tunnel in
                let prepared = try await worker.prepareConfiguration(settings: settings, credentialRevision: revision,
                    tunnel: tunnel, runtimeId: runtimeId, geodataId: geodataId, chainKey: chainKey)
                let result = try await perform(prepared)
                guard try await worker.settings().revision == settings.revision else { throw WorkerClientError.staleConfiguration }
                return result
            }
            status = "WARP 凭据已保存"
            return result
        } catch {
            status = "连接配置准备未完成"
            if let failure = error as? CredentialError, failure == .conflict || failure == .invalidCredential {
                summary = nil; inspected = false
            }
            throw error
        }
    }

    func inspect() {
        start("正在读取钥匙串…") {
            self.summary = try await self.workflow.inspect()
            self.inspected = true
            self.status = self.summary == nil ? "尚无本机 WARP 凭据" : "WARP 凭据已保存"
        }
    }

    func inspectForStartup() async throws {
        guard !busy, !hasPending else { throw RegistrationWorkflowError.busy }
        busy = true
        defer { busy = false }
        summary = try await workflow.inspect(interactionAllowed: false)
        inspected = true
        status = summary == nil ? "尚无本机 WARP 凭据" : "WARP 凭据已保存"
    }

    func register(replacing: Bool = false) {
        guard inspected, !hasPending, replacing || summary == nil else { return }
        let name = self.name
        let revision = replacing ? summary?.revision : nil
        start("正在检查钥匙串访问权限…") { [self] in
            let operation = self.operation
            self.summary = try await self.workflow.register(name: name, replacing: revision, willSave: { [weak self] in
                Task { @MainActor in
                    guard self?.operation == operation else { return }
                    self?.acceptsProgress = false
                    self?.canCancel = false
                    self?.status = "正在保存到钥匙串…"
                }
            }) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.operation == operation, self.acceptsProgress, progress.sequence > self.lastProgress else { return }
                    self.lastProgress = progress.sequence
                    self.canCancel = true
                    self.status = progress.phase == "enrolling" ? "正在配置 WARP 密钥…" : "正在注册 WARP 设备…"
                }
            }
            self.inspected = true
            self.status = "WARP 凭据已保存"
        }
    }

    func retrySave() {
        start("正在保存到钥匙串…") {
            self.summary = try await self.workflow.retrySave()
            self.inspected = true
            self.status = "WARP 凭据已保存"
        }
    }

    func discardPending() {
        start("正在放弃未保存的结果…") {
            try await self.workflow.discardPending()
            self.summary = nil; self.inspected = false
            self.status = "已放弃本次结果，请重新检查已保存凭据"
        }
    }

    func delete() {
        guard let revision = summary?.revision, !hasPending else { return }
        start("正在删除本机凭据…") {
            try await self.workflow.delete(revision: revision)
            self.summary = nil; self.inspected = true
            self.status = "已删除本机 WARP 凭据"
        }
    }

    func cancel() { if canCancel { task?.cancel() } }

    private func start(_ status: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; canCancel = false; self.status = status
        operation = UUID(); lastProgress = 0; acceptsProgress = true
        task = Task {
            do { try await action() }
            catch is CancellationError { self.status = "注册已取消，服务端可能已创建设备" }
            catch { self.error = error.localizedDescription; self.status = "WARP 操作未完成" }
            // Retire the progress generation before awaiting actor state.
            operation = nil; acceptsProgress = false
            hasPending = await workflow.hasPendingCredential
            if hasPending { self.status = "注册结果尚未保存到钥匙串" }
            busy = false; canCancel = false; task = nil
        }
    }
}

struct WarpAccountView: View {
    @ObservedObject var model: WarpModel
    @State private var confirmation: Action?
    private enum Action { case replace, delete, discard }

    var body: some View {
        GroupBox("WARP 账户") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.status).font(.headline)
                TextField("设备名称", text: $model.name)
                    .disabled(model.busy || model.hasPending)
                HStack {
                    Button("检查已保存凭据") { model.inspect() }.disabled(model.busy || model.hasPending)
                    if model.summary == nil {
                        Button("注册 WARP") { model.register() }
                            .disabled(!model.inspected || model.busy || model.hasPending)
                    } else {
                        Button("重新注册…") { confirmation = .replace }.disabled(model.busy || model.hasPending)
                        Button("删除本机凭据…") { confirmation = .delete }.disabled(model.busy || model.hasPending)
                    }
                }
                if model.busy { ProgressView().controlSize(.small) }
                if model.canCancel { Button("取消注册") { model.cancel() } }
                if model.hasPending {
                    Text("新凭据尚未存入钥匙串。退出前请重试保存或明确放弃本次结果。")
                        .font(.callout)
                    HStack {
                        Button("重试保存") { model.retrySave() }.disabled(model.busy)
                        Button("放弃本次结果…") { confirmation = .discard }.disabled(model.busy)
                    }
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
                Text("先检查本机是否已有凭据。注册会向 Cloudflare 创建设备；私钥存入当前用户的钥匙串，不写入普通配置文件。系统授权请在弹窗中处理。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            switch confirmation {
            case .replace: Button("重新注册", role: .destructive) { model.register(replacing: true) }
            case .delete: Button("删除本机凭据", role: .destructive) { model.delete() }
            case .discard: Button("放弃", role: .destructive) { model.discardPending() }
            case nil: EmptyView()
            }
        } message: {
            Text(confirmation == .replace ? "新凭据成功保存后会替换旧凭据；失败时旧凭据保留。" : "这只处理本机保存或待保存的凭据，不会撤销 Cloudflare 服务端的设备注册。")
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .replace: return "重新注册并替换 WARP 凭据？"
        case .delete: return "删除本机 WARP 凭据？"
        case .discard: return "放弃尚未保存的新凭据？"
        case nil: return "确认操作"
        }
    }
}
