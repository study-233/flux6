import SwiftUI
import FreeV6Business

struct MaintainerNoticeView: View {
    @ObservedObject var model: BusinessModel
    @AppStorage("maintainerNoticeReadIDs") private var storedIDs = Data()
    @State private var expandedID: String?
    @State private var openedInitialItem = false

    private var readIDs: [String] { (try? JSONDecoder().decode([String].self, from: storedIDs)) ?? [] }
    private var currentIDs: [String] { model.notice?.items.map(\.id) ?? [] }

    private func markRead(_ ids: [String]) {
        guard ids.contains(where: { !readIDs.contains($0) }) else { return }
        let recent = (readIDs.filter { !ids.contains($0) } + ids).suffix(50)
        if let data = try? JSONEncoder().encode(Array(recent)) { storedIDs = data }
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView { noticeContent }
                .onChange(of: expandedID) { _, id in
                    guard let id else { return }
                    reader.scrollTo(id, anchor: .top)
                    markRead([id])
                }
        }
    }

    private var noticeContent: some View {
        OverviewSection("维护者公告") {
            HStack {
                Button("刷新公告") { Task { await model.refreshNotice() } }.disabled(model.checkingNotice)
                if model.checkingNotice { ProgressView().controlSize(.small) }
                Spacer()
                if currentIDs.contains(where: { !readIDs.contains($0) }) {
                    Button("全部标为已读") { markRead(currentIDs) }
                }
            }
            if let stamp = model.notice?.fetchedAt, let date = ISO8601DateFormatter().date(from: stamp) {
                Text((model.notice?.source == .cache ? "本机缓存 · " : "更新于 ") + date.formatted())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.noticeError { Text(error).foregroundStyle(.secondary) }
            if let notice = model.notice {
                if notice.items.isEmpty {
                    Text(notice.source == .unavailable ? "暂时无法取得公告。" : "暂无有效公告。").foregroundStyle(.secondary)
                }
                ForEach(notice.items) { item in
                    Divider()
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedID == item.id },
                        set: { open in expandedID = open ? item.id : nil; if open { markRead([item.id]) } }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let date = ISO8601DateFormatter().date(from: item.published) {
                                Text(date.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            if let body = item.body { Text(verbatim: body).textSelection(.enabled) }
                            if let url = item.detailURL { Link(item.linkText ?? "查看详情", destination: url) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    } label: {
                        HStack {
                            Label(item.title, systemImage: item.level == .info ? "info.circle" : "exclamationmark.triangle")
                                .font(.headline)
                            if !readIDs.contains(item.id) { Text("未读").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.id(item.id)
                }
            }
        }
        .onChange(of: currentIDs, initial: true) {
            guard !openedInitialItem, !currentIDs.isEmpty else { return }
            openedInitialItem = true
            // Put the first unread item in view even when read notices precede it.
            if let first = currentIDs.first(where: { !readIDs.contains($0) }) {
                expandedID = first
            }
        }
    }
}
