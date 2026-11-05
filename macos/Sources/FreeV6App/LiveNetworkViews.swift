import SwiftUI
import Charts
import FreeV6Business
import FreeV6Desktop
import FreeV6System

extension CoreMode {
    var title: String {
        switch self { case .rule: return "规则"; case .global: return "全局"; case .direct: return "直连" }
    }
}

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
}

struct RuntimeMenus: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = model.controls.state
        let target = model.network.runningTarget
        Menu("工作模式") {
            if let state, let target {
                ForEach(CoreMode.allCases, id: \.self) { mode in
                    Toggle(mode.title, isOn: Binding(get: { state.mode == mode }, set: { _ in
                        guard mode != state.mode else { return }
                        Task { await model.changeMode(mode, target: target, token: state.token) }
                    }))
                }
            }
        }.disabled(target == nil || state == nil || model.controls.writing || model.business.busy || model.business.snapshot == nil)
        Menu("切换节点") {
            if let state, let target {
                ForEach(state.groups, id: \.group) { list in
                    Section(list.group.title) {
                        if list.group == .access, list.automatic {
                            Toggle("自动选择接入点", isOn: Binding(get: { list.preferred == nil }, set: { _ in
                                Task { await model.useAutomaticSelection(target: target, token: state.token) }
                            }))
                        }
                        let names = quickNames(list)
                        ForEach(names, id: \.self) { member in
                            Toggle(member, isOn: Binding(get: { (list.automatic ? list.preferred : list.selected) == member }, set: { _ in
                                guard member != (list.automatic ? list.preferred : list.selected) else { return }
                                Task { await model.selectMember(member, group: list.group, target: target, token: state.token) }
                            }))
                        }
                    }
                }
                Divider()
            }
            Button("全部节点…") { model.perform(.showPage(.nodes), in: .application, openWindow: openWindow) }
        }.disabled(model.controls.writing)
        if let error = model.modeSaveError ?? model.controls.error { Text(error) }
    }

    private func quickNames(_ list: SessionNodeList) -> [String] {
        var names = [String]()
        let candidates = [list.selected].compactMap { $0 } + model.controls.recentMembers(list.group) + list.members
        for name in candidates where list.members.contains(name) && !names.contains(name) {
            names.append(name)
            if names.count == 5 { break }
        }
        return names
    }
}

struct NodesView: View {
    @ObservedObject var model: AppModel
    @State private var filter = ""
    var body: some View {
        if let state = model.controls.state, let target = model.network.runningTarget, let list = model.availableGroup {
            VStack(alignment: .leading) {
                Picker("分组", selection: Binding(get: { list.group }, set: {
                    model.controls.cancelMeasurement()
                    model.nodeGroup = $0
                })) {
                    ForEach(state.groups, id: \.group) { Text($0.group.title).tag($0.group) }
                }.pickerStyle(.segmented)
                if list.group == .access, list.automatic {
                    HStack {
                        Text(list.preferred.map { "首选接入点 · " + $0 } ?? "自动选择接入点")
                        if list.preferred != nil {
                            Button("恢复自动选择") { Task { await model.useAutomaticSelection(target: target, token: state.token) } }
                                .disabled(model.controls.writing)
                        }
                    }
                }
                if model.controls.measuring { Button("停止测速") { model.controls.cancelMeasurement() } }
                List(list.members.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { member in
                    HStack {
                        Image(systemName: list.selected == member ? "checkmark.circle.fill" : "circle")
                            .accessibilityLabel(list.selected == member ? "当前节点" : "未选用")
                        Text(member).lineLimit(1).help(member)
                        Spacer()
                        if let delay = model.controls.latency[list.group]?[member] { Text(latency(delay)).monospacedDigit() }
                        Button("测速") { Task { await model.measure(group: list.group, members: [member]) } }
                            .disabled(model.controls.measuring)
                        Button("选用") {
                            Task { await model.selectMember(member, group: list.group, target: target, token: state.token) }
                        }.disabled(model.controls.writing || (list.automatic ? list.preferred : list.selected) == member)
                    }
                }.searchable(text: $filter, prompt: "搜索节点")
            }
        } else {
            Text(model.network.phase == .running ? (model.controls.state == nil ? "正在读取可用节点…" : "当前配置没有可选节点。") : "连接后可以查看接入点、切换节点并测速。")
                .foregroundStyle(.secondary)
        }
        if let error = model.controls.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }

    private func latency(_ delay: CoreDelay) -> String {
        switch delay { case .measured(let ms): return "\(ms) ms"; case .unavailable: return "不可用"; case .timedOut: return "超时" }
    }
}

struct TrafficStatisticsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GroupBox("流量统计") {
            VStack(alignment: .leading, spacing: 5) {
                if let report = model.trafficReport {
                    Text("\(report.month) · 上传 \(bytes(report.monthly.upload)) · 下载 \(bytes(report.monthly.download))")
                    Text("全部累计 · 上传 \(bytes(report.total.upload)) · 下载 \(bytes(report.total.download))")
                } else if model.accountingError == nil { Text("正在读取流量记录…") }
                if let error = model.accountingError { Text(error).foregroundStyle(.red) }
            }.font(.callout).monospacedDigit().padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TrafficOverview: View {
    @ObservedObject var controls: DesktopCoreControls
    var body: some View {
        GroupBox("本次会话流量") {
            VStack(alignment: .leading, spacing: 8) {
                TrafficRates(controls: controls)
                if let sample = controls.currentTraffic {
                    Text("累计上传 \(bytes(sample.upTotal)) · 下载 \(bytes(sample.downTotal))")
                        .font(.callout).monospacedDigit()
                }
                if controls.history.count > 1 {
                    Chart(controls.history) { point in
                        ForEach([true, false], id: \.self) { up in
                            LineMark(x: .value("时间", point.date), y: .value("字节/秒", Double(up ? point.sample.up : point.sample.down)))
                                .foregroundStyle(by: .value("方向", up ? "上传" : "下载"))
                        }
                    }.frame(height: 95)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TrafficRates: View {
    @ObservedObject var controls: DesktopCoreControls
    var body: some View {
        if let sample = controls.currentTraffic {
            Text("上传 \(bytes(sample.up))/秒 · 下载 \(bytes(sample.down))/秒").monospacedDigit()
        } else { Text(controls.trafficError ?? "等待读取速率…").foregroundStyle(.secondary) }
    }
}
