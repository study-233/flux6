import FreeV6Desktop
import FreeV6System
import SwiftUI

struct DashboardNode: View {
    @ObservedObject var model: AppModel
    @State private var presented = false
    @State private var openedGroup: DesktopNodeGroup?
    @FocusState private var rowFocused: Bool
    @State private var hovering = false
    @Environment(\.openWindow) private var openWindow

    private var group: DesktopNodeGroup? {
        model.nodeOptions.first { $0.group == .access } ?? model.displayedNodeGroup
    }

    var body: some View {
        content
        .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            if let openedGroup {
                NodeChoices(model: model, initial: openedGroup, close: { presented = false }, openNodes: { group in
                    presented = false
                    openNodes(group)
                })
            }
        }
        .onChange(of: model.network.runningTarget) { presented = false }
        .onChange(of: model.browsingOfflineNodes) {
            if !model.browsingOfflineNodes && model.network.runningTarget == nil { presented = false }
        }
        .onChange(of: presented) {
            if !presented && model.page == .overview { Task { @MainActor in rowFocused = true } }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let group, !group.members.isEmpty {
                nodeRow(group)
            } else if model.network.phase == .running {
                if let error = model.controls.readError {
                    Text("无法读取节点").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.primary.opacity(0.78)).textSelection(.enabled)
                    Button("重新读取") { Task { await model.refreshCoreControls() } }
                } else if model.controls.state == nil {
                    ProgressView("正在读取节点…").controlSize(.small)
                } else {
                    Text("当前没有可用节点").font(.headline)
                    Button("全部节点…") { openNodes(group?.group) }.buttonStyle(.link)
                }
            } else {
                Text(model.connectionTitle).font(.headline)
                if model.network.phase == .recovering || model.network.phase == .occupied || model.network.phase == .unknown {
                    DesktopCommandButton(model.commandState.primaryCommand, model: model)
                } else if model.browsingOfflineNodes {
                    Text("暂无可选节点").font(.callout).foregroundStyle(.secondary)
                    Button("查看节点") { openNodes(group?.group) }.buttonStyle(.link)
                }
            }
        }
    }

    private func nodeRow(_ group: DesktopNodeGroup) -> some View {
        let node = group.selected ?? group.chosen ?? (group.automatic ? "自动选择" : "分组默认")
        let strategy = policy(group)
        let spoken = "更换\(group.group.title)，\(node)，\(strategy)"
        return Button {
            openedGroup = group
            presented = true
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(node).font(.title3.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.primary.opacity(0.78))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(strategy).foregroundStyle(.primary.opacity(0.78)).lineLimit(2)
                    Spacer(minLength: 5)
                    Text("更换节点").foregroundStyle(Color.accentColor).fixedSize()
                }.font(.callout)
            }
            .padding(4).frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.secondary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlPressStyle()).focused($rowFocused)
        .onHover { hovering = $0 }
        .help(group.selected ?? group.group.title)
        .accessibilityLabel(spoken)
    }

    private func policy(_ group: DesktopNodeGroup) -> String {
        if group.source == .previousSession { return "上次会话列表 · 下次生效" }
        if group.source == .configuration { return "本地配置 · 下次生效" }
        guard group.automatic else { return group.group.title }
        return group.preferred.map { "首选：" + $0 } ?? "自动选择"
    }

    private func openNodes(_ group: SessionNodeGroup?) {
        if let group { model.nodeGroup = group }
        model.perform(.showPage(.nodes), in: .main(.overview), openWindow: openWindow)
    }
}

private enum NodeChoice: Hashable {
    case automatic
    case member(String)
    var title: String {
        switch self { case .automatic: "自动选择"; case .member(let name): name }
    }
}

private struct NodeChoices: View {
    @ObservedObject var model: AppModel
    let initial: DesktopNodeGroup
    let close: () -> Void
    let openNodes: (SessionNodeGroup) -> Void
    @State private var query = ""
    @State private var active: NodeChoice?
    @State private var pending: NodeChoice?
    @State private var failed: NodeChoice?
    @State private var failure: String?
    @FocusState private var searchFocused: Bool

    private var available: DesktopNodeGroup? { model.nodeOptions.first { $0.group == initial.group } }
    private var list: DesktopNodeGroup { available ?? initial }
    private var matches: [NodeChoice] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let auto = (list.automatic || list.source != .session) && (term.isEmpty || automaticLabel.localizedCaseInsensitiveContains(term))
        let names = quickNodeCandidates(list, recent: model.controls.recentMembers(list.group, in: list.members), query: term)
        return (auto ? [.automatic] : []) + names.map(NodeChoice.member)
    }

    private var automaticLabel: String { list.automatic ? "自动选择" : "分组默认" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(initial.group == .access ? "更换接入节点" : "更换" + initial.group.title + "节点").font(.headline)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.primary.opacity(0.78))
                TextField("搜索节点", text: $query).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let choice = active ?? matches.first { select(choice) } }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                        move(key.key == .upArrow ? -1 : 1)
                        return .handled
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("清除节点搜索")
                }
            }
            .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Color.accentColor : .clear) }
            if list.source != .session {
                Text(list.source == .configuration ? "来自本地配置，选择用于下次连接。" : "来自上次会话，连接时核对可用性。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if available == nil {
                Text("此分组已不可用。").foregroundStyle(.primary.opacity(0.78))
            } else if matches.isEmpty {
                Text("没有匹配的节点").foregroundStyle(.primary.opacity(0.78))
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(matches, id: \.self) { choice in option(choice).id(choice) }
                        }
                    }
                    .frame(height: CGFloat(min(matches.count, 5)) * 31)
                    .onChange(of: active) { if let active { reader.scrollTo(active) } }
                }
            }
            if let error = failure ?? model.controls.readError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Button("重试") {
                    let choice = failed
                    Task {
                        if model.network.runningTarget != nil, available == nil { await model.refreshCoreControls() }
                        if let choice, available != nil { select(choice) }
                    }
                }.disabled(pending != nil)
            }
            Divider()
            Button("全部节点…") { openNodes(initial.group) }.buttonStyle(.link)
        }
        .padding(14).frame(width: 282)
        .task { searchFocused = true }
        .onChange(of: query) { active = nil }
        .onExitCommand(perform: close)
    }

    private func checked(_ choice: NodeChoice) -> Bool {
        switch choice {
        case .automatic: list.chosen == nil
        case .member(let name): list.chosen == name
        }
    }

    private func option(_ choice: NodeChoice) -> some View {
        let selected = checked(choice)
        let current = choice == list.selected.map(NodeChoice.member)
        return Button { select(choice) } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
                Text(choice == .automatic ? automaticLabel : choice.title).lineLimit(2)
                Spacer(minLength: 4)
                if pending == choice {
                    ProgressView().controlSize(.mini)
                } else if current {
                    Text("使用中").font(.caption.weight(.medium)).foregroundStyle(.primary.opacity(0.78))
                }
            }
            .padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
            .background(active == choice ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlPressStyle()).disabled(available == nil || pending != nil || model.controls.writing)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(choice == .automatic ? automaticLabel : choice.title)
    }

    private func move(_ step: Int) {
        let items = matches
        guard !items.isEmpty else { return }
        let index = active.flatMap { items.firstIndex(of: $0) } ?? (step > 0 ? -1 : items.count)
        active = items[min(max(index + step, 0), items.count - 1)]
    }

    private func select(_ choice: NodeChoice) {
        guard pending == nil, !model.controls.writing, available != nil else { return }
        let target = model.network.runningTarget
        if checked(choice) { close(); return }
        failed = nil
        failure = nil
        pending = choice
        Task {
            let success: Bool
            switch choice {
            case .automatic: success = await model.chooseNode(nil, in: initial.group, expecting: target)
            case .member(let member):
                success = await model.chooseNode(member, in: initial.group, expecting: target)
            }
            pending = nil
            guard model.network.runningTarget == target else { return }
            if success { close() }
            else {
                failed = choice
                failure = model.controls.selectionError ?? "节点状态已更新，请重试。"
            }
        }
    }
}
