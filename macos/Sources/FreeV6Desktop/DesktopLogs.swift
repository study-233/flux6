import Combine
import Foundation
import FreeV6System

@MainActor public final class DesktopLogs: ObservableObject {
    @Published public var level: EventLevel?
    @Published public private(set) var paused: [UserEvent]?
    @Published public private(set) var records: [UserEvent] = []
    @Published public private(set) var storageUnavailable = false
    private var pending: [UserEvent] = []
    private var delivery: Task<Void, Never>?
    private let journal: UserEventJournal?

    public init(directory: URL?) {
        journal = directory.map(UserEventJournal.init(root:))
        guard let journal else { storageUnavailable = true; return }
        delivery = Task {
            do {
                let existing = try await Task.detached(priority: .utility) { try journal.history() }.value
                records = Self.bounded(existing + records)
            } catch { storageUnavailable = true }
            await drain()
        }
    }

    // Keep the newest events for each independent source, even when another
    // source is noisy. An unavailable disk must not stop in-memory collection.
    private static func bounded(_ rows: [UserEvent]) -> [UserEvent] {
        var counts: [EventSource: Int] = [:]
        return rows.reversed().filter {
            let source = $0.event.source
            counts[source, default: 0] += 1
            return counts[source, default: 0] <= UserEventJournal.perSourceLimit
        }.reversed()
    }

    public func record(_ event: DesktopEvent) {
        let entry = UserEvent(event)
        records = Self.bounded(records + [entry])
        guard journal != nil else { return }
        pending = Self.bounded(pending + [entry])
        if delivery == nil { delivery = Task { await drain() } }
    }

    private func drain() async {
        defer { delivery = nil }
        guard let journal else { return }
        while !pending.isEmpty {
            let batch = pending
            pending = []
            do {
                try await Task.detached(priority: .utility) { try journal.append(batch) }.value
                storageUnavailable = false
            } catch {
                pending = Self.bounded(batch + pending)
                storageUnavailable = true
                return
            }
        }
    }

    public func finishWrites() async {
        if let delivery { await delivery.value }
        if !pending.isEmpty, delivery == nil {
            delivery = Task { await drain() }
            await delivery?.value
        }
    }

    public var visible: [UserEvent] {
        let rows = paused ?? records
        guard let level else { return rows }
        return rows.filter { $0.event.level == level }
    }

    public func togglePause() { paused = paused == nil ? records : nil }

    public static func text(_ rows: [UserEvent]) -> String {
        let stamp = ISO8601DateFormatter()
        return rows.map { row in
            "\(stamp.string(from: row.date))  [\(row.event.level.rawValue)] [\(row.event.source.title)] \(row.event.rawValue)"
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
}

public struct DesktopDiagnosticSnapshot {
    private let header: [String]

    public init(version: String?, service: DesktopServiceState, network: DesktopNetworkPhase,
                coreReady: Bool?, geodataReady: Bool?, settingsLoaded: Bool) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        let validVersion = version.flatMap { value in
            value.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$"#, options: .regularExpression) == value.startIndex..<value.endIndex ? value : nil
        }
        func resource(_ value: Bool?) -> String {
            guard let value else { return "待检查" }
            return value ? "已校验" : "待准备"
        }
        header = ["FreeV6 脱敏诊断", "应用版本  " + (validVersion ?? "未知"),
                  "macOS  \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · " + arch,
                  "服务协议  \(ServiceProtocolVersion.current)", "服务状态  " + service.title,
                  "连接状态  " + network.title, "本机配置  " + (settingsLoaded ? "已载入" : "待载入"),
                  "网络核心  " + resource(coreReady), "规则数据  " + resource(geodataReady)]
    }

    @MainActor public func text(events: [UserEvent]) -> String {
        header.joined(separator: "\n") + "\n\n最近事件\n" + DesktopLogs.text(events)
    }
}
