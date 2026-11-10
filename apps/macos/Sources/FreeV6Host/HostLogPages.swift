import Foundation
import FreeV6Desktop
import FreeV6System

/// Cursors belong to one ordered, filtered view. Record IDs remain stable when a source reaches its retention cap.
@MainActor final class HostLogPages {
    static let pageSize = 32
    private let logs: DesktopLogs
    private var generation: UUID?
    private var epoch = UUID().uuidString
    private var entries: [UserEvent] = []
    private var cursors: [UUID: Int] = [:]
    private var highest = 0
    private var floors: [String: Int] = [:]

    init(_ logs: DesktopLogs) { self.logs = logs }

    private func update() {
        let next = logs.visible
        if generation == logs.viewGeneration, entries == next { return }
        var reset = generation != logs.viewGeneration
        if !reset {
            // Loading disk history can insert earlier records. Ordinary appends and per-source eviction keep the old order.
            var foundNew = false, previous = 0
            for entry in next {
                if let cursor = cursors[entry.id] {
                    if foundNew || cursor <= previous { reset = true; break }
                    previous = cursor
                } else { foundNew = true }
            }
        }
        if reset { cursors = [:]; highest = 0; epoch = UUID().uuidString }
        var assigned: [UUID: Int] = [:], oldest: [String: Int] = [:]
        for entry in next {
            let cursor: Int
            if let prior = cursors[entry.id] { cursor = prior }
            else { highest += 1; cursor = highest }
            assigned[entry.id] = cursor
            let source = entry.event.source.title
            if oldest[source] == nil { oldest[source] = cursor }
        }
        entries = next; cursors = assigned; floors = oldest; generation = logs.viewGeneration
    }

    func metadata() -> [String: Any] {
        update()
        return ["epoch": epoch, "newest": entries.last.flatMap { cursors[$0.id] } ?? 0, "count": entries.count,
                "floors": floors, "level": logs.level?.rawValue ?? "全部", "paused": logs.paused != nil,
                "storageUnavailable": logs.storageUnavailable, "clearError": logs.clearError ?? "",
                "canClear": logs.canClear, "clearing": logs.isClearing]
    }

    private func row(_ entry: UserEvent) -> [String: Any] {
        ["id": entry.id.uuidString, "cursor": cursors[entry.id]!, "time": Int64(entry.date.timeIntervalSince1970 * 1000),
         "level": entry.event.level.rawValue, "source": entry.event.source.title, "message": entry.event.rawValue]
    }

    func read(_ args: [String: Any]) throws -> [String: Any] {
        let view = metadata()
        let after = args["after"] as? Int, before = args["before"] as? Int
        let supplied = args["epoch"] as? String
        guard after == nil || before == nil, after.map({ $0 >= 0 }) ?? true, before.map({ $0 > 0 }) ?? true,
              (after == nil && before == nil) || supplied != nil else { throw SettingsFailure("无效的日志游标。") }
        if let supplied, supplied != epoch { return ["view": view, "reset": true, "rows": []] }
        let page: [UserEvent]
        if let after {
            // Take the earliest unseen entries first so a burst larger than a page is delivered without gaps.
            page = Array(entries.lazy.filter { self.cursors[$0.id]! > after }.prefix(Self.pageSize).reversed())
        } else {
            page = Array(entries.reversed().lazy.filter { entry in before.map { self.cursors[entry.id]! < $0 } ?? true }.prefix(Self.pageSize))
        }
        return ["view": view, "reset": false, "rows": page.map(row)]
    }

    func export(_ args: [String: Any]) throws -> [String: Any] {
        update()
        guard args["epoch"] as? String == epoch else { throw SettingsFailure("日志视图已变化，请重新导出。") }
        return ["epoch": epoch, "text": DesktopLogs.text(entries)]
    }
}
