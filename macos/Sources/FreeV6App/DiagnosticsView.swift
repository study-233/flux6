import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import FreeV6Business
import FreeV6Desktop
import FreeV6System

extension AppModel {
    func observeLogEvents() -> Set<AnyCancellable> {
        var subscriptions = Set<AnyCancellable>()
        func observe<P: Publisher>(_ publisher: P) where P.Output == DesktopEvent?, P.Failure == Never {
            publisher.removeDuplicates().compactMap { $0 }.sink { [weak logs] in logs?.record($0) }.store(in: &subscriptions)
        }
        func observeFailure(_ publisher: Published<String?>.Publisher, _ event: DesktopEvent) {
            observe(publisher.map { $0 == nil ? nil : event })
        }
        observe($serviceState.map { state in
            switch state {
            case .ready: return .serviceReady
            case .missing: return .serviceMissing
            case .needsRepair: return .serviceFailure
            case .checking, .managing: return nil
            }
        })
        observe(network.$phase.map { phase in
            switch phase {
            case .idle: return .idle
            case .connecting: return .connecting
            case .running: return .connected
            case .disconnecting: return .disconnecting
            case .occupied: return .occupied
            case .recovering: return .recovery
            case .unknown: return nil
            }
        })
        observeFailure(network.$statusError, .unknown)
        observeFailure(network.$error, .operationFailed)
        observeFailure(controls.$readError, .controlFailure)
        observeFailure(controls.$selectionError, .controlFailure)
        observeFailure(controls.$modeError, .controlFailure)
        observeFailure(controls.$measurementError, .controlFailure)
        observeFailure(business.$error, .settingsFailure)
        observeFailure(business.$chainError, .profileFailure)
        observeFailure(business.$cloudError, .profileFailure)
        observeFailure(warp.$error, .accountFailure)
        observeFailure(core.$error, .coreFailure)
        observeFailure(geodata.$error, .geodataFailure)
        observeFailure($configurationError, .preparationFailure)
        observe($configurationSummary.map { $0 == nil ? nil : .prepared })
        observe(core.$package.map { $0.map { $0.available ? .coreReady : .coreNeeded } })
        observe(geodata.$package.map { $0.map { $0.available ? .geodataReady : .geodataNeeded } })
        var hadSettings = false
        business.$snapshot.compactMap { $0?.revision }.removeDuplicates().sink { [weak logs] _ in
            logs?.record(hadSettings ? .settingsChanged : .settingsReady)
            hadSettings = true
        }.store(in: &subscriptions)
        business.$checkingNotice.dropFirst().filter { !$0 }.sink { [weak self] _ in
            guard let self else { return }
            switch self.business.notice?.source {
            case .online: self.logs.record(.noticeOnline)
            case .cache: self.logs.record(.noticeCache)
            case .unavailable, .none: self.logs.record(.noticeMissing)
            }
        }.store(in: &subscriptions)
        return subscriptions
    }

    func diagnosticText() -> String {
        DesktopDiagnosticSnapshot(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            service: serviceState, network: network.phase, coreReady: core.package?.available,
            geodataReady: geodata.package?.available, settingsLoaded: business.snapshot != nil).text(events: logs.records)
    }
}

struct LogLevelPicker: View {
    @ObservedObject var logs: DesktopLogs
    var body: some View {
        Picker("日志级别", selection: $logs.level) {
            Text("全部级别").tag(nil as EventLevel?)
            ForEach(EventLevel.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.accessibilityLabel("日志级别")
    }
}

struct LogActions: View {
    @ObservedObject var logs: DesktopLogs
    var body: some View {
        Button {
            logs.togglePause()
        } label: {
            Label(logs.paused == nil ? "暂停显示" : "继续显示", systemImage: logs.paused == nil ? "pause" : "play")
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    private var logs: DesktopLogs { model.logs }
    @State private var selected: UserEvent.ID?
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("日志").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Text("\(logs.visible.count) 条记录").font(.callout).foregroundStyle(.secondary)
                Spacer()
                LogLevelPicker(logs: logs).pickerStyle(.menu).labelsHidden().fixedSize()
                LogActions(logs: logs)
                DesktopCommandButton(.exportLogs, model: model, context: .main(.logs))
                Button("清空…", systemImage: "trash") { confirmClear = true }
                    .accessibilityLabel("清空全部日志").help("清空所有级别的 FreeV6 应用事件")
                    .disabled(!logs.canClear)
                    .confirmationDialog("清空全部日志？", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("清空全部日志", role: .destructive) { selected = nil; logs.clear() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将清空全部级别的应用事件，包括暂停显示的记录与本机保存的历史。已导出的文件和系统服务日志会保留。")
                    }
            }.padding(.horizontal, 20).padding(.top, 12)
            if logs.isClearing {
                HStack { ProgressView().controlSize(.small); Text("正在清空本机日志…") }
                    .font(.callout).padding(.horizontal, 20)
            } else if let failure = logs.clearError {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).padding(.horizontal, 20)
            } else if logs.storageUnavailable {
                Label {
                    Text("无法保存本机日志。仍可导出本次运行的事件。")
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .font(.callout).padding(.horizontal, 20)
            }
            if logs.paused != nil {
                Label("显示已暂停，后台继续记录事件。", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            if logs.visible.isEmpty {
                if logs.didClear && (logs.paused ?? logs.records).isEmpty {
                    ContentUnavailableView("日志已清空", systemImage: "list.bullet.rectangle", description:
                        Text(logs.paused == nil ? "新的事件会继续出现在这里。" : "点“继续显示”查看后续事件。"))
                } else {
                    ContentUnavailableView(logs.level == nil ? "暂无日志" : "当前级别暂无事件", systemImage: "list.bullet.rectangle")
                }
            } else {
                Table(Array(logs.visible.reversed()), selection: $selected) {
                    TableColumn("时间") { entry in
                        Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.width(min: 100, ideal: 124)
                    TableColumn("级别") { entry in
                        Text(entry.event.level.rawValue)
                            .foregroundStyle(color(entry.event.level))
                    }.width(44)
                    TableColumn("来源") { entry in
                        Text(entry.event.source.title).foregroundStyle(.secondary)
                    }.width(min: 50, ideal: 75)
                    TableColumn("事件") { entry in
                        Text(entry.event.rawValue).textSelection(.enabled)
                    }.width(min: 110, ideal: 245)
                }
                .contextMenu(forSelectionType: UserEvent.ID.self) { ids in
                    if let entry = logs.visible.first(where: { ids.contains($0.id) }) {
                        Button("复制这条日志") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DesktopLogs.text([entry]), forType: .string)
                        }
                    }
                }
            }
        }
    }

    private func color(_ level: EventLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
