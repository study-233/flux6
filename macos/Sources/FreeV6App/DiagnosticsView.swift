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
        observeFailure(controls.$error, .controlFailure)
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
    @ObservedObject var logs: DesktopLogs

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if logs.storageUnavailable {
                Text("无法保存本机日志。仍可导出本次运行的事件。").foregroundStyle(.secondary)
            }
            if logs.paused != nil { Text("显示已暂停，后台继续记录事件。").foregroundStyle(.secondary) }
            if logs.visible.isEmpty {
                Text("当前级别暂无事件。").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(logs.visible.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.event.level.rawValue)
                            .foregroundStyle(entry.event.level == .error ? Color.red : .secondary)
                        Text(entry.event.source.title).foregroundStyle(.secondary)
                        Text(entry.event.rawValue).textSelection(.enabled)
                    }.font(.callout)
                    .contextMenu {
                        Button("复制这条日志") {
                            let text = DesktopLogs.text([entry])
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                }
            }
        }
    }
}
