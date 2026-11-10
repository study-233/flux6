import CoreGraphics
import Foundation

public enum DashboardWidget: String, CaseIterable, Codable, Sendable {
    case connection, mode, node, usage, speed
}

public enum DashboardSize: String, Codable, Sendable {
    case compact, wide
}

public struct DashboardTile: Identifiable, Equatable, Sendable {
    public let kind: DashboardWidget
    public var size: DashboardSize
    public var id: DashboardWidget { kind }

    public init(_ kind: DashboardWidget, size: DashboardSize? = nil) {
        self.kind = kind
        self.size = size ?? (kind == .speed ? .wide : .compact)
    }
}

public struct DashboardLayout: Equatable, Sendable {
    public private(set) var tiles: [DashboardTile]
    public init() { tiles = DashboardWidget.allCases.map { DashboardTile($0) } }

    private struct Record: Codable {
        let kind: String
        let size: String?
    }
    private struct Document: Codable {
        let version: Int
        let tiles: [Record]
    }

    public init(data: Data?) {
        self.init()
        guard let data, let doc = try? JSONDecoder().decode(Document.self, from: data),
              doc.version == 1 else { return }
        var seen = Set<DashboardWidget>()
        let recognized = doc.tiles.compactMap { record -> DashboardTile? in
            guard let kind = DashboardWidget(rawValue: record.kind), seen.insert(kind).inserted else { return nil }
            return DashboardTile(kind, size: record.size.flatMap(DashboardSize.init(rawValue:)))
        }
        if doc.tiles.isEmpty || !recognized.isEmpty { tiles = recognized }
    }

    public func encoded() throws -> Data {
        let records = tiles.map { Record(kind: $0.kind.rawValue, size: $0.size.rawValue) }
        return try JSONEncoder().encode(Document(version: 1, tiles: records))
    }

    public func contains(_ kind: DashboardWidget) -> Bool { tiles.contains { $0.kind == kind } }

    public mutating func add(_ kind: DashboardWidget) {
        if !contains(kind) { tiles.append(DashboardTile(kind)) }
    }
    public mutating func remove(_ kind: DashboardWidget) { tiles.removeAll { $0.kind == kind } }
    public mutating func resize(_ kind: DashboardWidget, to size: DashboardSize) {
        if let i = tiles.firstIndex(where: { $0.kind == kind }) { tiles[i].size = size }
    }

    public mutating func move(_ moving: [DashboardWidget], before destination: DashboardWidget?) {
        let selection = Set(moving)
        let moved = tiles.filter { selection.contains($0.kind) }
        guard !moved.isEmpty, destination.map({ contains($0) && !selection.contains($0) }) ?? true else { return }
        tiles.removeAll { selection.contains($0.kind) }
        let insertion = tiles.firstIndex { $0.kind == destination } ?? tiles.endIndex
        tiles.insert(contentsOf: moved, at: insertion)
    }

    public mutating func move(_ kind: DashboardWidget, onto target: DashboardWidget) {
        guard kind != target, let from = tiles.firstIndex(where: { $0.kind == kind }),
              let to = tiles.firstIndex(where: { $0.kind == target }) else { return }
        let before = from < to ? tiles.dropFirst(to + 1).first?.kind : target
        move([kind], before: before)
    }

    public mutating func step(_ kind: DashboardWidget, by offset: Int) {
        guard let index = tiles.firstIndex(where: { $0.kind == kind }), [-1, 1].contains(offset),
              tiles.indices.contains(index + offset) else { return }
        tiles.swapAt(index, index + offset)
    }
}

public enum DashboardGridGeometry {
    /// Measure each tile at its assigned width, then align all tiles in its row.
    public static func frames(width: CGFloat, spans: [Int], height: (Int, CGFloat) -> CGFloat) -> [CGRect] {
        let gap: CGFloat = 12
        let columns = width >= 805 ? 3 : width >= 500 ? 2 : 1
        let unit = max(1, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        var frames: [CGRect] = []
        var column = 0, rowStart = 0
        var top: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, preferred) in spans.enumerated() {
            let requestedSpan = min(columns, max(1, preferred))
            // A wide tile can share the row with a compact tile in a narrow window.
            let span = columns == 2 && column == 1 ? 1 : requestedSpan
            if column + span > columns {
                for i in rowStart..<frames.count { frames[i].size.height = rowHeight }
                top += rowHeight + gap
                rowHeight = 0
                column = 0
                rowStart = frames.count
            }
            let tileWidth = unit * CGFloat(span) + gap * CGFloat(span - 1)
            let tileHeight = height(index, tileWidth)
            frames.append(CGRect(x: CGFloat(column) * (unit + gap), y: top, width: tileWidth, height: tileHeight))
            column += span
            rowHeight = max(rowHeight, tileHeight)
        }
        for i in rowStart..<frames.count { frames[i].size.height = rowHeight }
        return frames
    }
}
