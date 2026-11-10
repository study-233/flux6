import FreeV6Business
import FreeV6Desktop
import SwiftUI

enum DashboardTrafficTint {
    static func download(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.36, green: 0.84, blue: 0.84) : Color(red: 0.05, green: 0.44, blue: 0.46)
    }

    static func upload(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.73, green: 0.66, blue: 0.99) : Color(red: 0.37, green: 0.29, blue: 0.65)
    }
}

struct DashboardUsageCard: View {
    @ObservedObject var model: AppModel
    let allTime: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = model.trafficReport {
                let bytes = allTime ? report.total : report.monthly
                let values = DashboardTrafficUsage(upload: bytes.upload, download: bytes.download)
                let period = allTime ? "累计" : report.month
                let total = formattedDashboardBytes(values.total)
                let down = formattedDashboardBytes(Decimal(bytes.download))
                let up = formattedDashboardBytes(Decimal(bytes.upload))
                VStack(alignment: .leading, spacing: 10) {
                    Text(total).font(.title.bold()).monospacedDigit()
                        .contentTransition(.opacity)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            if values.total == 0 {
                                Capsule().fill(.quaternary)
                            } else {
                                Rectangle().fill(DashboardTrafficTint.upload(scheme))
                                Rectangle().fill(DashboardTrafficTint.download(scheme))
                                    .frame(width: proxy.size.width * values.downloadFraction)
                            }
                        }.clipShape(Capsule())
                    }.frame(height: 6)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 22) {
                            direction("下载", symbol: "arrow.down", value: down, tint: DashboardTrafficTint.download(scheme))
                            direction("上传", symbol: "arrow.up", value: up, tint: DashboardTrafficTint.upload(scheme))
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 5) {
                            direction("下载", symbol: "arrow.down", value: down, tint: DashboardTrafficTint.download(scheme))
                            direction("上传", symbol: "arrow.up", value: up, tint: DashboardTrafficTint.upload(scheme))
                        }
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: allTime)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(period + "，总用量 " + total + "，下载 " + down + "，上传 " + up)
            } else if model.accountingError == nil {
                ProgressView("正在读取用量…").controlSize(.small)
            }
            if let error = model.accountingError {
                if model.trafficReport != nil { Text("上次读取的数据").font(.caption.weight(.semibold)) }
                Text(error).font(.callout).foregroundStyle(.primary.opacity(0.78)).textSelection(.enabled)
                Button("重试") { Task { await model.loadTrafficReport() } }
            }
        }
    }

    private func direction(_ title: String, symbol: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label { Text(title).foregroundStyle(.primary.opacity(0.78)) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.callout)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}

func formattedDashboardBytes(_ bytes: Decimal) -> String {
    if bytes <= Decimal(Int64.max) {
        return formattedTrafficBytes(NSDecimalNumber(decimal: bytes).uint64Value)
    }
    let exabytes = bytes / Decimal(1_000_000_000_000_000_000 as UInt64)
    return exabytes.formatted(.number.precision(.fractionLength(0...2))) + " EB"
}


struct UsagePeriodSwitch: View {
    @Binding var allTime: Bool
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool?

    var body: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { lifetime in
                let selected = lifetime == allTime
                let title = lifetime ? "累计" : "本月"
                Button {
                    allTime = lifetime
                } label: {
                    VStack(spacing: 3) {
                        Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : .secondary)
                        ZStack {
                            Color.clear
                            if selected {
                                Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "period", in: underline)
                            }
                        }.frame(width: 23, height: 2)
                    }.padding(.horizontal, 5).padding(.vertical, 2).contentShape(Rectangle())
                }
                .buttonStyle(ControlPressStyle()).focused($focused, equals: lifetime)
                .accessibilityLabel("统计周期，" + title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
                    let next = key.key == .rightArrow
                    allTime = next
                    focused = next
                    return .handled
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: allTime)
        .accessibilityElement(children: .contain)
    }
}
