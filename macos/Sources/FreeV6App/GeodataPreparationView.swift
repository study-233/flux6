import SwiftUI
import FreeV6Business

@MainActor final class GeodataModel: ObservableObject {
    @Published var package: GeodataPackageInfo?
    @Published var progress: WorkerProgress?
    @Published var busy = false
    @Published var status = "尚未检查规则数据"
    @Published var error: String?
    private let session: BusinessSession
    private var operation: UUID?
    private var preparation: Task<Void, Never>?

    init(session: BusinessSession) { self.session = session }
    var canCancel: Bool { preparation != nil }

    func refresh() async {
        guard !busy else { return }
        busy = true; error = nil; progress = nil; status = "正在校验规则数据…"
        defer { busy = false }
        do { accept(try await session.worker().geodataStatus()) }
        catch { self.error = error.localizedDescription; package = nil; status = "规则数据检查未完成" }
    }

    func beginPreparation() {
        guard !busy else { return }
        busy = true; error = nil; progress = nil; status = "正在准备规则数据…"
        let operation = UUID()
        self.operation = operation
        preparation = Task { [self] in
            defer { busy = false; preparation = nil; self.operation = nil }
            do {
                let result = try await session.worker().prepareGeodata { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == operation else { return }
                        if let previous = self.progress, previous.sequence >= update.sequence { return }
                        self.progress = update
                        switch update.phase {
                        case "downloading": self.status = "正在下载 \(update.asset ?? "规则数据")…"
                        case "copying": self.status = "正在准备本地规则数据…"
                        default: self.status = "正在校验规则数据…"
                        }
                    }
                }
                accept(result)
            } catch is CancellationError {
                package = nil; progress = nil; status = "已请求取消，可重新检查或继续准备"
            } catch {
                self.error = error.localizedDescription; package = nil; progress = nil; status = "规则数据准备未完成"
            }
        }
    }

    func cancel() { preparation?.cancel() }

    private func accept(_ result: GeodataPackageInfo) {
        package = result; progress = nil
        status = result.available ? "规则数据已校验" : "需要准备规则数据"
    }
}

struct GeodataPreparationView: View {
    @ObservedObject var model: GeodataModel
    var body: some View {
        GroupBox("规则数据") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.status).font(.headline)
                if let package = model.package {
                    ForEach(package.files, id: \.name) { file in
                        Label(file.name, systemImage: file.available ? "checkmark.circle" : "arrow.down.circle")
                            .font(.callout)
                            .accessibilityLabel("\(file.name)：\(file.available ? "已校验" : "需要准备")")
                    }
                }
                if model.busy {
                    if let progress = model.progress, progress.phase == "downloading", progress.total > 0 {
                        ProgressView(value: min(Double(progress.received), Double(progress.total)), total: Double(progress.total))
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)) · 线路 \(progress.attempt)/\(progress.attempts)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button("准备规则数据") { model.beginPreparation() }.disabled(model.busy || model.package?.available == true)
                    Button("检查本地数据") { Task { await model.refresh() } }.disabled(model.busy)
                    if model.canCancel { Button("取消") { model.cancel() } }
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                Text("首次准备需要下载域名与 IP 分类数据。已校验的文件可重复使用；准备数据不会开启代理。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
