import SwiftUI
import FreeV6Business

struct MaintainerNoticeView: View {
    @ObservedObject var model: BusinessModel
    @AppStorage("maintainerNoticeReadIDs") private var storedIDs = Data()
    @State private var expanded = false

    private var readIDs: [String] { (try? JSONDecoder().decode([String].self, from: storedIDs)) ?? [] }
    private var currentIDs: [String] { model.notice?.items.map(\.id) ?? [] }

    private func markRead() {
        let ids = currentIDs
        guard expanded, !ids.isEmpty else { return }
        let recent = (readIDs.filter { !ids.contains($0) } + ids).suffix(50)
        if let data = try? JSONEncoder().encode(Array(recent)) { storedIDs = data }
    }

    var body: some View {
        GroupBox("维护者公告") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("刷新公告") { Task { await model.refreshNotice() } }.disabled(model.checkingNotice)
                    if model.checkingNotice { ProgressView().controlSize(.small) }
                    if let stamp = model.notice?.fetchedAt, let date = ISO8601DateFormatter().date(from: stamp) {
                        Text((model.notice?.source == .cache ? "本机缓存 · " : "更新于 ") + date.formatted())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.noticeError { Text(error).foregroundStyle(.secondary) }
                if let notice = model.notice {
                    if notice.items.isEmpty {
                        Text(notice.source == .unavailable ? "暂时无法取得公告。" : "暂无有效公告。").foregroundStyle(.secondary)
                    } else {
                        let unread = currentIDs.filter { !readIDs.contains($0) }.count
                        DisclosureGroup(unread > 0 ? "查看公告（\(unread) 条未读）" : "查看公告", isExpanded: $expanded) {
                            ForEach(notice.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(item.title, systemImage: item.level == .info ? "info.circle" : "exclamationmark.triangle")
                                        .font(.headline)
                                    if let date = ISO8601DateFormatter().date(from: item.published) {
                                        Text(date.formatted()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let body = item.body { Text(verbatim: body).textSelection(.enabled) }
                                    if let url = item.detailURL { Link(item.linkText ?? "查看详情", destination: url) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .onChange(of: expanded) { _ in markRead() }
        .onChange(of: currentIDs) { _ in markRead() }
    }
}
