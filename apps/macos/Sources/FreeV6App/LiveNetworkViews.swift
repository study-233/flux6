import SwiftUI
import FreeV6Desktop
import FreeV6System

extension CoreMode {
    var title: String {
        switch self { case .rule: return "规则"; case .global: return "全局"; case .direct: return "直连" }
    }
}

func formattedTrafficBytes(_ value: UInt64) -> String {
    value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
}

/// An empty search offers quick choices. A search always considers every member of the group.
func quickNodeCandidates(_ list: DesktopNodeGroup, recent: [String], query: String = "") -> [String] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !term.isEmpty { return list.members.filter { $0.localizedCaseInsensitiveContains(term) } }
    var choices = [String]()
    let candidates = [list.selected, list.preferred].compactMap { $0 } + recent + list.members
    for name in candidates where list.members.contains(name) && !choices.contains(name) {
        choices.append(name)
        if choices.count == 5 { break }
    }
    return choices
}

struct RuntimeMenus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        RuntimeModeMenu(model: model)
        RuntimeNodeMenu(model: model)
        if let error = model.modeSaveError ?? model.controls.error { Text(error) }
    }
}

struct RuntimeModeSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section(model.network.phase == .running ? "工作模式 · 立即生效，并用于下次连接" : "下次连接模式") { RuntimeModeChoices(model: model) }
    }
}

struct RuntimeModeMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu("工作模式") { RuntimeModeSection(model: model) }
    }
}

private struct RuntimeModeChoices: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ForEach(CoreMode.allCases, id: \.self) { mode in
            Toggle(mode.title, isOn: Binding(get: { model.workingMode == mode }, set: { selected in
                guard selected, model.workingMode != mode else { return }
                Task { await model.selectWorkingMode(mode) }
            }))
        }.disabled(!model.canSelectWorkingMode)
    }
}

struct RuntimeNodeMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let target = model.network.runningTarget
        let groups = model.nodeOptions
        return Menu(target == nil ? "下次连接节点" : "切换节点") {
            ForEach(groups) { list in
                Section(list.group.title) {
                    if list.automatic || list.source != .session {
                        Toggle(list.automatic ? "自动选择接入点" : "使用分组默认", isOn: Binding(get: { list.chosen == nil }, set: { selected in
                            guard selected, list.chosen != nil else { return }
                            Task { await model.chooseNode(nil, in: list.group, expecting: target) }
                        }))
                    }
                    let recent = model.controls.recentMembers(list.group, in: list.members)
                    ForEach(quickNodeCandidates(list, recent: recent), id: \.self) { member in
                        Toggle(member, isOn: Binding(get: { list.chosen == member }, set: { selected in
                            guard selected, list.chosen != member else { return }
                            Task { await model.chooseNode(member, in: list.group, expecting: target) }
                        }))
                    }
                }
            }
            if !groups.isEmpty { Divider() }
            Button("全部节点…") { model.perform(.showPage(.nodes), in: .application, openWindow: openWindow) }
        }.disabled(model.controls.writing || model.promptActive || model.terminating || model.updater.preparingInstallation)
    }
}

struct NodesView: View {
    @ObservedObject var model: AppModel
    @State private var filter = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedNode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("节点").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                searchField
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if let list = model.displayedNodeGroup {
                nodeList(list, target: model.network.runningTarget)
            } else {
                unavailableContent
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("查找节点")
            TextField("搜索节点", text: $filter).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索节点")
            if !filter.isEmpty {
                Button { clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: 220)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    private func clearSearch() { filter = ""; searchFocused = true }

    @ViewBuilder private func nodeList(_ list: DesktopNodeGroup, target: SessionControlTarget?) -> some View {
        let term = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = term.isEmpty ? list.members : list.members.filter { $0.localizedCaseInsensitiveContains(term) }
        summary(list, online: target != nil, target: target)
        HStack(spacing: 12) {
            if model.nodeOptions.count > 1 {
                Picker("节点分组", selection: Binding(get: { list.group }, set: {
                    model.controls.cancelMeasurement()
                    model.nodeGroup = $0
                })) {
                    ForEach(model.nodeOptions) { Text($0.group.title).tag($0.group) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            } else { Text(list.group.title + "列表").font(.headline) }
            Text(String(names.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if target != nil {
                if model.controls.measuring {
                    Button("停止测速") { model.controls.cancelMeasurement() }
                } else {
                    Button(term.isEmpty ? "测量全组 \(names.count) 个节点" : "测量 \(names.count) 个结果") {
                        Task { await model.measure(group: list.group, members: names) }
                    }.disabled(names.isEmpty)
                    if !term.isEmpty {
                        Menu("其他测速") {
                            Button("测量全组 \(list.members.count) 个节点") {
                                Task { await model.measure(group: list.group, members: list.members) }
                            }
                        }.fixedSize()
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 8)
        if let error = model.controls.selectionError { errorLine("节点选择", error: error) }
        if let error = model.controls.measurementError { errorLine("节点测速失败", error: error) }
        Divider()
        if names.isEmpty, !term.isEmpty {
            ContentUnavailableView {
                Label("没有匹配的节点", systemImage: "magnifyingglass")
            } description: { Text("此分组中没有包含“\(term)”的节点。") }
            actions: { Button("清除搜索") { clearSearch() } }
        } else if names.isEmpty {
            emptyGroups
        } else {
            ScrollViewReader { reader in
                List(names, id: \.self) { name in
                    nodeRow(name, list: list, target: target)
                        .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                        .id(name)
                }.listStyle(.plain)
                .onChange(of: focusedNode) { if let focusedNode { reader.scrollTo(focusedNode) } }
                .onMoveCommand { direction in
                    guard let focusedNode, let index = names.firstIndex(of: focusedNode) else { return }
                    if direction == .up { self.focusedNode = names[max(index - 1, 0)] }
                    if direction == .down { self.focusedNode = names[min(index + 1, names.count - 1)] }
                }
            }
        }
    }

    private func summary(_ list: DesktopNodeGroup, online: Bool, target: SessionControlTarget?) -> some View {
        let title = online ? (list.selected ?? "尚未选定") : (list.chosen ?? (list.automatic ? "自动选择" : "使用分组默认"))
        return HStack(spacing: 12) {
            Image(systemName: online ? "network" : "bookmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(online ? Color.green : Color.accentColor)
                .frame(width: 36, height: 36)
                .background((online ? Color.green : Color.accentColor).opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(online ? "当前使用" : "下次连接").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold)).lineLimit(2).help(title)
                Text(sourceTitle(list)).font(.callout).foregroundStyle(.primary.opacity(0.74)).lineLimit(2)
            }
            Spacer(minLength: 6)
            if list.chosen != nil && (list.automatic || !online) { policyButton(list, target: target) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)) }
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    private func sourceTitle(_ list: DesktopNodeGroup) -> String {
        switch list.source {
        case .configuration: "本地配置 · 选择用于下次连接"
        case .previousSession: "上次连接的节点 · 下次连接时核对"
        case .session: list.automatic ? (list.preferred.map { "当前会话 · 首选：" + $0 } ?? "当前会话 · 自动选择接入点") : "当前会话 · 手动选择"
        }
    }

    private func policyButton(_ list: DesktopNodeGroup, target: SessionControlTarget?) -> some View {
        let selected = list.chosen == nil
        let text = list.automatic ? (selected ? "自动选择" : "恢复自动选择") : "使用分组默认"
        return Button { Task { await model.chooseNode(nil, in: list.group, expecting: target) } } label: {
            Label(text, systemImage: selected ? "checkmark" : "arrow.uturn.backward")
        }.disabled(selected || model.controls.writing)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func nodeRow(_ name: String, list: DesktopNodeGroup, target: SessionControlTarget?) -> some View {
        let chosen = list.chosen == name
        let current = target != nil && list.selected == name
        let text = [current ? "使用中" : nil, chosen ? (target == nil ? "下次连接" : list.automatic ? "首选" : nil) : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Button {
                if !chosen { Task { await model.chooseNode(name, in: list.group, expecting: target) } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Color.accentColor : Color.secondary).accessibilityHidden(true)
                    Text(name).font(.body.weight(chosen || current ? .semibold : .regular)).lineLimit(2)
                    if !text.isEmpty {
                        Text(text).font(.caption.weight(.medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((current ? Color.green : Color.accentColor).opacity(0.11), in: Capsule())
                    }
                    Spacer(minLength: 4)
                }.padding(.vertical, 7).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(ControlPressStyle()).focused($focusedNode, equals: name)
            .disabled(model.controls.writing).accessibilityLabel("选用\(name)")
            .accessibilityValue(text).accessibilityAddTraits(chosen ? .isSelected : []).help(name)
            if target != nil {
                let testing = model.controls.measuringGroup == list.group && model.controls.measuringMember == name
                Text(testing ? "测量中…" : model.controls.latency[list.group]?[name].map(latency) ?? "未测")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Button { Task { await model.measure(group: list.group, members: [name]) } } label: {
                    Image(systemName: "speedometer").frame(width: 30, height: 28).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(model.controls.measuring)
                .accessibilityLabel("测量\(name)延迟").help("测量\(name)延迟")
            }
        }
    }

    private func errorLine(_ title: String, error: String) -> some View {
        Label("\(title)：\(error)", systemImage: "exclamationmark.triangle")
            .font(.callout).textSelection(.enabled).padding(.horizontal, 20).padding(.bottom, 8)
    }

    @ViewBuilder private var unavailableContent: some View {
        switch model.network.phase {
        case .running:
            if let error = model.controls.readError {
                ContentUnavailableView {
                    Label("读取节点失败", systemImage: "exclamationmark.triangle")
                } description: { Text(error).textSelection(.enabled) } actions: { retryReading }
            } else if model.controls.state == nil {
                ProgressView("正在读取可用节点…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { emptyGroups }
        case .connecting, .disconnecting:
            ProgressView(model.connectionTitle).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle where model.browsingOfflineNodes, .unknown where model.browsingOfflineNodes:
            ContentUnavailableView {
                Label(model.business.busy ? "正在读取节点配置…" : "暂无离线节点", systemImage: "network")
            } description: { Text(model.business.error ?? "读取本地配置后即可选择下次连接的节点。") }
            actions: { Button("读取本地配置") { Task { await model.business.reload() } }.disabled(model.business.busy) }
        case .unknown, .idle, .recovering, .occupied:
            ContentUnavailableView {
                Label(model.connectionTitle, systemImage: model.connectionSymbol)
            } description: {
                Text(sessionDescription)
            } actions: {
                DesktopCommandButton(model.commandState.primaryCommand, model: model)
            }
        }
    }

    private var sessionDescription: String {
        if let error = model.network.statusError ?? model.network.error { return error }
        switch model.network.phase {
        case .recovering: return "恢复网络后才能选择节点。"
        case .occupied: return "其他登录用户结束会话后，可刷新状态。"
        case .unknown: return model.serviceStatus
        default: return "建立连接后，可以测速、选择首选节点或恢复自动选择。"
        }
    }

    private var emptyGroups: some View {
        ContentUnavailableView {
            Label("暂无可用节点", systemImage: "network")
        } description: { Text(model.browsingOfflineNodes ? "此来源没有可供选择的节点。" : "当前会话没有可显示的节点。") }
        actions: { if !model.browsingOfflineNodes { retryReading } }
    }

    private var retryReading: some View {
        Button(model.controls.inspecting ? "正在读取…" : "重新读取节点") {
            Task { await model.refreshCoreControls() }
        }.disabled(model.controls.inspecting)
    }

    private func latency(_ delay: CoreDelay) -> String {
        switch delay { case .measured(let ms): return "\(ms) ms"; case .unavailable: return "不可用"; case .timedOut: return "超时" }
    }
}

struct TrafficRates: View {
    @ObservedObject var controls: DesktopCoreControls
    var body: some View {
        if let sample = controls.currentTraffic {
            Text("上传 \(formattedTrafficBytes(sample.up))/秒 · 下载 \(formattedTrafficBytes(sample.down))/秒").monospacedDigit()
        } else { Text(controls.trafficError ?? "等待读取速率…").foregroundStyle(.secondary) }
    }
}
