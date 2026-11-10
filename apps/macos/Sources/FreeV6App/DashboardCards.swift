import SwiftUI
import FreeV6Desktop
import FreeV6System

struct DashboardCardContent: View {
    let tile: DashboardTile
    @ObservedObject var model: AppModel
    let allTime: Bool

    var body: some View {
        switch tile.kind {
        case .connection: ConnectionControl(model: model)
        case .mode: DashboardMode(model: model)
        case .node: DashboardNode(model: model)
        case .usage: DashboardUsageCard(model: model, allTime: allTime)
        case .speed:
            SpeedCard(controls: model.controls, running: model.network.phase == .running, wide: tile.size == .wide)
        }
    }
}

private struct ConnectionControl: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let command = model.commandState.primaryCommand
        let available = model.commandState.availability(command)
        let busy = model.network.phase.busy || model.serviceState.busy
        let action = command == .disconnect ? "断开连接" : command.title
        let tint: Color = model.network.phase == .running
            ? (scheme == .dark ? .mint : Color(red: 0.10, green: 0.43, blue: 0.28)) : .accentColor
        Button {
            model.perform(command, in: .main(.overview), openWindow: openWindow)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.10))
                    Circle().strokeBorder(tint.opacity(0.34))
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: command == .connect || command == .disconnect ? "power" : command.symbol)
                            .font(.system(size: 23, weight: .medium)).foregroundStyle(tint)
                    }
                }.frame(width: 53, height: 53)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.connectionTitle).font(.title2.bold())
                    Text(busy ? "请稍候" : action).font(.subheadline).foregroundStyle(.primary.opacity(0.78))
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(ControlPressStyle())
        .disabled(!available.enabled)
        .help(available.reason ?? action)
        .accessibilityLabel(model.connectionTitle + "，" + action)
    }
}

struct ModeSegments: View {
    let title: String
    let selection: CoreMode?
    var pending: CoreMode? = nil
    let onSelect: (CoreMode) -> Void
    @FocusState private var focus: CoreMode?
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var slider

    // Preserve the system accent hue while keeping white text readable on light accent choices.
    private var selectedFill: Color {
        let accent = Color.accentColor.resolve(in: environment)
        let luminance = 0.2126 * accent.linearRed + 0.7152 * accent.linearGreen + 0.0722 * accent.linearBlue
        let factor = luminance > 0.17 ? 0.17 / luminance : 1
        return Color(.sRGBLinear, red: Double(accent.linearRed * factor),
                     green: Double(accent.linearGreen * factor), blue: Double(accent.linearBlue * factor))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CoreMode.allCases, id: \.self) { mode in
                let selected = mode == selection
                Button {
                    if !selected && pending == nil { onSelect(mode) }
                } label: {
                    HStack(spacing: 3) {
                        ZStack {
                            if pending == mode {
                                ProgressView().controlSize(.mini)
                            } else if selected {
                                Image(systemName: "checkmark").font(.caption.bold())
                            }
                        }.frame(width: 12)
                        Text(mode.title).fontWeight(selected ? .semibold : .regular)
                    }
                    .foregroundStyle(selected ? Color.white : .primary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6).fill(selectedFill)
                                .matchedGeometryEffect(id: "selection", in: slider)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ControlPressStyle()).focused($focus, equals: mode)
                .accessibilityLabel(title + "，" + mode.title)
                .accessibilityValue(pending == mode ? "正在切换" : (selected ? "已选中" : "未选中"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
                    guard pending == nil, let index = CoreMode.allCases.firstIndex(of: mode) else { return .handled }
                    let next = index + (key.key == .rightArrow ? 1 : -1)
                    guard CoreMode.allCases.indices.contains(next) else { return .handled }
                    let destination = CoreMode.allCases[next]
                    focus = destination
                    if destination != selection { onSelect(destination) }
                    return .handled
                }
            }
        }
        .padding(3).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
    }
}

private struct DashboardMode: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var scopeDescription: String {
        switch model.workingModeSource {
        case .savedDefault where model.workingMode == nil:
            return model.business.error == nil ? "正在读取默认模式…" : "默认模式读取失败"
        case .savedDefault: return "下次连接使用所选模式"
        case .liveSession where model.workingMode == nil:
            return model.controls.readError == nil ? "正在读取当前模式…" : "当前模式读取失败"
        case .liveSession: return "立即生效，并用于下次连接"
        case nil: return model.connectionTitle
        }
    }

    var body: some View {
        let source = model.workingModeSource
        VStack(alignment: .leading, spacing: 7) {
            ModeSegments(title: source == .savedDefault ? "下次连接模式" : "当前工作模式",
                         selection: model.workingMode, pending: model.pendingWorkingMode) { mode in
                Task { await model.selectWorkingMode(mode) }
            }
            .disabled(!model.canSelectWorkingMode && model.pendingWorkingMode == nil)
            Text(scopeDescription)
                .font(.callout).foregroundStyle(.primary.opacity(0.78))
            let defaultReadError = source == .savedDefault && model.business.snapshot == nil ? model.business.error : nil
            if let error = model.modeSaveError ?? model.controls.modeError ?? model.controls.readError ?? defaultReadError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    if let failed = model.failedWorkingMode {
                        Button("重试") {
                            Task {
                                if model.workingModeSource == .liveSession && model.controls.state == nil {
                                    await model.refreshCoreControls()
                                }
                                if model.failedWorkingMode == failed { await model.selectWorkingMode(failed) }
                            }
                        }.disabled(model.pendingWorkingMode != nil)
                    } else if model.controls.readError != nil && source == .liveSession {
                        Button("重新读取") { Task { await model.refreshCoreControls() } }.disabled(model.controls.inspecting)
                    } else if defaultReadError != nil {
                        Button("重新读取") { Task { await model.business.reload() } }.disabled(model.business.busy)
                    }
                    if model.modeSaveError != nil {
                        Button("查看配置") { model.perform(.showPage(.configuration), in: .main(.overview), openWindow: openWindow) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

private struct SpeedCard: View {
    @ObservedObject var controls: DesktopCoreControls
    let running: Bool
    let wide: Bool
    @Environment(\.colorScheme) private var scheme
    private var downloadTint: Color { DashboardTrafficTint.download(scheme) }
    private var uploadTint: Color { DashboardTrafficTint.upload(scheme) }
    var body: some View {
        let sample = running ? controls.currentTraffic : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 28) {
                rate("下载", symbol: "arrow.down", value: sample?.down, color: downloadTint)
                rate("上传", symbol: "arrow.up", value: sample?.up, color: uploadTint)
            }
            Group {
                if sample != nil && !controls.history.isEmpty { chart }
                else { emptyPlot }
            }.frame(height: wide ? 82 : 48)
        }
    }

    private var chart: some View {
        let history = controls.history
        let (peakDown, peakUp) = history.reduce(into: (UInt64(0), UInt64(0))) { peaks, point in
            peaks.0 = max(peaks.0, point.sample.down)
            peaks.1 = max(peaks.1, point.sample.up)
        }
        let peak = max(peakDown, peakUp)
        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                if wide {
                    VStack(alignment: .trailing) {
                        if peak != 0 { Text(formattedDashboardBytes(Decimal(peak)) + "/s") }
                        Spacer(minLength: 0)
                        Text("0 B/s")
                    }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                SpeedPlot(history: history, peak: peak, downloadTint: downloadTint, uploadTint: uploadTint)
            }
            if wide, let first = history.first, let last = history.last {
                HStack {
                    Text(first.date, format: .dateTime.minute().second())
                    Spacer()
                    if last.id != first.id { Text(last.date, format: .dateTime.minute().second()) }
                }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("速率曲线")
        .accessibilityValue("\(history.count) 个样本，下载峰值 " + formattedDashboardBytes(Decimal(peakDown)) + "/s，上传峰值 " + formattedDashboardBytes(Decimal(peakUp)) + "/s")
    }

    private var emptyPlot: some View {
        let message = running ? controls.trafficError ?? "等待速率样本…" : "连接后显示速率曲线"
        return ZStack {
            VStack(spacing: 0) {
                Divider()
                Spacer()
                Divider()
                Spacer()
                Divider()
            }.accessibilityHidden(true)
            Text(message).font(.callout).foregroundStyle(.primary.opacity(0.78)).multilineTextAlignment(.center)
                .padding(.horizontal, 6).background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func rate(_ title: String, symbol: String, value: UInt64?, color: Color) -> some View {
        let text = value.map { formattedDashboardBytes(Decimal($0)) + "/s" } ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            Label { Text(title).foregroundStyle(.primary.opacity(0.78)) } icon: { Image(systemName: symbol).foregroundStyle(color) }
                .font(.subheadline)
            Text(text).font(.title3.weight(.semibold)).monospacedDigit()
        }.accessibilityElement(children: .ignore).accessibilityLabel(title + "，" + (value == nil ? "无速率样本" : text))
    }
}

private struct SpeedPlot: View {
    let history: [TrafficReading]
    let peak: UInt64
    let downloadTint: Color
    let uploadTint: Color

    var body: some View {
        Canvas { context, size in
            guard let first = history.first, let last = history.last else { return }
            let inset: CGFloat = 2
            let width = max(0, size.width - inset * 2)
            let height = max(0, size.height - inset * 2)
            var grid = Path()
            for fraction: CGFloat in [0, 0.5, 1] {
                let y = inset + fraction * height
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.20)), lineWidth: 0.5)
            let duration = last.date.timeIntervalSince(first.date)
            for up in [false, true] {
                var line = Path()
                var previous: Date?
                let tint = up ? uploadTint : downloadTint
                let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: up ? [4, 3] : [])
                for reading in history {
                    let elapsed = reading.date.timeIntervalSince(first.date)
                    let x = duration > 0 ? inset + width * min(1, max(0, elapsed / duration)) : size.width / 2
                    let value = Double(up ? reading.sample.up : reading.sample.down)
                    let y = inset + height * (1 - value / max(1, Double(peak)))
                    let point = CGPoint(x: x, y: y)
                    if let previous, reading.date.timeIntervalSince(previous) < 8 {
                        line.addLine(to: point)
                    } else {
                        // Sleeping or hiding the window stops visible sampling. Leave that interval blank.
                        line.move(to: point)
                        let dot = CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)
                        context.fill(Path(ellipseIn: dot), with: .color(tint))
                    }
                    previous = reading.date
                }
                context.stroke(line, with: .color(tint), style: style)
            }
        }
    }
}
