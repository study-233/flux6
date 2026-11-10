import Combine
import Foundation
import FreeV6System

@MainActor public final class DesktopLogs: ObservableObject {
    public private(set) var viewGeneration = UUID()
    @Published public var level: EventLevel? {
        didSet { if level != oldValue { viewGeneration = UUID() } }
    }
    @Published public private(set) var paused: [UserEvent]?
    @Published public private(set) var records: [UserEvent] = []
    @Published public private(set) var storageUnavailable = false
    @Published public private(set) var isClearing = false
    @Published public private(set) var clearError: String?
    @Published public private(set) var didClear = false
    @Published private var loadingHistory = false
    private var arrivingDuringClear: [UserEvent] = []
    private var clearing: Task<Void, Never>?
    private var pending: [UserEvent] = []
    private var delivery: Task<Void, Never>?
    private let journal: UserEventJournal?

    public init(directory: URL?) {
        journal = directory.map(UserEventJournal.init(root:))
        guard let journal else { storageUnavailable = true; return }
        loadingHistory = true
        delivery = Task {
            do {
                let existing = try await Task.detached(priority: .utility) { try journal.history() }.value
                records = Self.bounded(existing + records)
            } catch { storageUnavailable = true }
            loadingHistory = false
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
        if isClearing { arrivingDuringClear = Self.bounded(arrivingDuringClear + [entry]) }
        guard journal != nil else { return }
        pending = Self.bounded(pending + [entry])
        if !isClearing && delivery == nil { delivery = Task { await drain() } }
    }

    private func drain() async {
        defer { delivery = nil }
        guard let journal else { return }
        while !isClearing && !pending.isEmpty {
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

    public var canClear: Bool {
        !isClearing && (loadingHistory || !records.isEmpty || paused?.isEmpty == false || storageUnavailable || clearError != nil)
    }

    // Set the boundary synchronously when the confirmation button is pressed. Drain only the
    // write already in flight; subsequent events have their own buffer until disk clearing ends.
    public func clear() {
        guard !isClearing else { return }
        let cutoff = Date()
        let previousWrite = delivery
        isClearing = true
        clearError = nil
        arrivingDuringClear = []
        clearing = Task {
            await previousWrite?.value
            do {
                let survivors: [UserEvent]
                if let journal {
                    survivors = try await Task.detached(priority: .utility) { try journal.clear(through: cutoff) }.value
                    storageUnavailable = false
                } else {
                    survivors = []
                    clearError = "已清空本次运行的记录。无法访问本机日志目录，已有磁盘历史未能确认。"
                }
                let persisted = Set(survivors.map(\.id))
                let unwritten = arrivingDuringClear.filter { !persisted.contains($0.id) }
                viewGeneration = UUID()
                records = Self.bounded((survivors + unwritten).sorted { $0.date < $1.date })
                if paused != nil { paused = [] }
                pending = journal == nil ? [] : unwritten
                didClear = true
            } catch ResourceStoreError.busy {
                clearError = "其他进程正在写入日志。请稍后重试清空。"
            } catch {
                storageUnavailable = true
                clearError = "本机日志未能全部清空。请检查日志目录和磁盘空间，然后重试。"
            }
            arrivingDuringClear = []
            isClearing = false
            clearing = nil
            if !pending.isEmpty && delivery == nil { delivery = Task { await drain() } }
        }
    }

    public func finishWrites() async {
        var retried = false
        while true {
            if let operation = clearing ?? delivery {
                await operation.value
                continue
            }
            guard !retried, !pending.isEmpty else { return }
            retried = true
            delivery = Task { await drain() }
        }
    }

    public var visible: [UserEvent] {
        let rows = paused ?? records
        guard let level else { return rows }
        return rows.filter { $0.event.level == level }
    }

    public func togglePause() {
        viewGeneration = UUID()
        paused = paused == nil ? records : nil
    }

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
        header = ["Flux6 脱敏诊断", "应用版本  " + (validVersion ?? "未知"),
                  "macOS  \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · " + arch,
                  "服务协议  \(ServiceProtocolVersion.current)", "服务状态  " + service.title,
                  "连接状态  " + network.title, "本机配置  " + (settingsLoaded ? "已载入" : "待载入"),
                  "网络核心  " + resource(coreReady), "规则数据  " + resource(geodataReady)]
    }

    @MainActor public func text(events: [UserEvent]) -> String {
        header.joined(separator: "\n") + "\n\n最近事件\n" + DesktopLogs.text(events)
    }
}
