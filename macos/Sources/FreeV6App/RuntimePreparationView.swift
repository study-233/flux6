import SwiftUI
import FreeV6Business

@MainActor final class RuntimeModel: ObservableObject {
    @Published var package: RuntimePackageInfo?
    @Published var progress: WorkerProgress?
    @Published var busy = false
    @Published var status = "尚未检查核心"
    @Published var error: String?
    private let session: BusinessSession
    private var operation: UUID?
    private var download: Task<Void, Never>?

    init(session: BusinessSession) { self.session = session }
    var canCancel: Bool { download != nil }

    func refresh() async {
        guard !busy else { return }
        busy = true; error = nil; progress = nil; status = "正在校验本地核心…"
        defer { busy = false }
        do { accept(try await session.worker().runtimeStatus()) }
        catch { self.error = error.localizedDescription; status = "检查未完成" }
    }

    func beginDownload() {
        guard !busy else { return }
        busy = true; error = nil; progress = nil; status = "正在准备核心…"
        let operation = UUID()
        self.operation = operation
        download = Task { [self] in
            defer { busy = false; download = nil; self.operation = nil }
            do {
                let result = try await session.worker().downloadRuntime { update in
                    Task { @MainActor [weak self] in
                        guard self?.operation == operation else { return }
                        if let previous = self?.progress, previous.sequence >= update.sequence { return }
                        self?.progress = update
                        self?.status = update.phase == "downloading" ? "正在下载核心…" : "正在校验核心…"
                    }
                }
                accept(result)
            } catch is CancellationError { status = "已请求取消，请重新检查本地核心" }
            catch { self.error = error.localizedDescription; status = "核心准备未完成" }
        }
    }

    func cancel() { download?.cancel() }

    private func accept(_ result: RuntimePackageInfo) {
        package = result; progress = nil
        status = result.available ? "核心安装包已校验" : "需要下载核心"
    }
}

struct RuntimePreparationView: View {
    @ObservedObject var model: RuntimeModel
    var body: some View {
        GroupBox("网络核心") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.status).font(.headline)
                if let package = model.package {
                    Text("mihomo \(package.version) · \(package.architecture == "arm64" ? "Apple Silicon" : "Intel")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.busy {
                    if let progress = model.progress, progress.phase == "downloading", progress.total > 0 {
                        ProgressView(value: min(Double(progress.received), Double(progress.total)), total: Double(progress.total))
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)) · 线路 \(progress.attempt)/\(progress.attempts)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                        if let progress = model.progress, progress.phase == "downloading" {
                            Text("已下载 \(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)) · 线路 \(progress.attempt)/\(progress.attempts)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("下载核心") { model.beginDownload() }.disabled(model.busy || model.package?.available == true)
                    Button("检查本地核心") { Task { await model.refresh() } }.disabled(model.busy)
                    if model.canCancel { Button("取消下载") { model.cancel() } }
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                Text("准备核心不会开启代理。连接功能将在网络服务接入后开放。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
