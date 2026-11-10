import SwiftUI
import FreeV6Desktop
import UniformTypeIdentifiers

extension DashboardWidget {
    var title: String {
        switch self {
        case .connection: "连接控制"
        case .speed: "实时速度"
        case .usage: "用量统计"
        case .node: "接入节点"
        case .mode: "工作模式"
        }
    }
    var symbol: String {
        switch self {
        case .connection: "power"
        case .speed: "waveform.path.ecg"
        case .usage: "chart.bar.fill"
        case .node: "point.3.connected.trianglepath.dotted"
        case .mode: "arrow.triangle.branch"
        }
    }
    var description: String {
        switch self {
        case .connection: "会话状态与一键启停"
        case .speed: "实时上下行速率与趋势曲线"
        case .usage: "本月和累计上传、下载用量"
        case .node: "当前接入点与快速切换"
        case .mode: "切换规则、全局或直连模式"
        }
    }
    var isControl: Bool {
        self == .connection || self == .mode || self == .node
    }
}

private struct TileSpan: LayoutValueKey { static let defaultValue: Int? = nil }

// A single ordered collection lets a dragged item move between rows as its span changes.
private struct TileGridLayout: Layout {
    let tiles: [DashboardTile]
    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        let spans = subviews.enumerated().map { index, view in
            // SwiftUI's reorder preview can wrap a child and hide its layout value.
            let preferred = tiles.indices.contains(index) && tiles[index].size == .wide ? 2 : 1
            return view[TileSpan.self] ?? preferred
        }
        return DashboardGridGeometry.frames(width: width, spans: spans) { index, tileWidth in
            subviews[index].sizeThatFits(.init(width: tileWidth, height: nil)).height
        }
    }

    struct Measurements {
        var width: CGFloat?
        var frames: [CGRect] = []
    }
    func makeCache(subviews: Subviews) -> Measurements { Measurements() }
    func updateCache(_ cache: inout Measurements, subviews: Subviews) { cache = Measurements() }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurements) -> CGSize {
        let width = proposal.width ?? 840
        cache = Measurements(width: width, frames: frames(width, subviews))
        return CGSize(width: width, height: cache.frames.last?.maxY ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurements) {
        let layout = cache.width == bounds.width && cache.frames.count == subviews.count
            ? cache.frames : frames(bounds.width, subviews)
        cache.width = nil
        for (view, frame) in zip(subviews, layout) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct TileDrag: Codable, Transferable {
    let kind: DashboardWidget
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "dev.freev6.dashboard-tile")).visibility(.ownProcess)
    }
}

private struct EditAnchors: PreferenceKey {
    struct Value {
        var cards: [DashboardWidget: Anchor<CGRect>] = [:]
        var handles: [DashboardWidget: Anchor<CGRect>] = [:]
    }
    static var defaultValue: Value { Value() }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.cards.merge(next.cards) { _, new in new }
        value.handles.merge(next.handles) { _, new in new }
    }
}

struct DashboardGrid: View {
    @ObservedObject var model: AppModel
    @Binding var showCatalog: Bool
    @GestureState private var hoverTarget: DashboardWidget?
    @State private var allTime = false

    var body: some View {
        if model.displayedDashboard.tiles.isEmpty {
            ContentUnavailableView {
                Label("仪表盘还没有小组件", systemImage: "rectangle.grid.2x2")
            } actions: {
                Button("添加小组件") {
                    if model.dashboardDraft == nil { model.dashboardDraft = model.dashboard }
                    showCatalog = true
                }
            }.frame(minHeight: 200)
        } else if model.dashboardDraft != nil {
            editor.overlayPreferenceValue(EditAnchors.self) { anchors in
                GeometryReader { proxy in
                    ForEach(model.displayedDashboard.tiles) { tile in
                        if let anchor = anchors.handles[tile.kind] {
                            let handle = proxy[anchor]
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary).frame(width: handle.width, height: handle.height)
                                .contentShape(Rectangle()).position(x: handle.midX, y: handle.midY)
                                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tileEditor"))
                                    .updating($hoverTarget) { value, target, _ in
                                        target = anchors.cards.first { proxy[$0.value].contains(value.location) }?.key
                                    }
                                    .onEnded { value in
                                        if let target = anchors.cards.first(where: { proxy[$0.value].contains(value.location) })?.key {
                                            model.dashboardDraft?.move(tile.kind, onto: target)
                                        }
                                    })
                                .help("拖动调整顺序").accessibilityHidden(true)
                        }
                    }
                }
            }.coordinateSpace(name: "tileEditor")
        } else {
            TileGridLayout(tiles: model.displayedDashboard.tiles) {
                ForEach(model.dashboard.tiles) { tile in card(tile, editing: false) }
            }
            .backgroundPreferenceValue(EditAnchors.self) { anchors in
                GeometryReader { proxy in
                    let surfaces = surfaces(anchors: anchors.cards, proxy: proxy)
                    ForEach(surfaces.indices, id: \.self) { index in
                        let surface = surfaces[index]
                        let frame = surface.frame
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.12)) }
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        ForEach(surface.dividers, id: \.self) { x in
                            Rectangle().fill(.separator)
                                .frame(width: 1, height: max(0, frame.height - 30))
                                .position(x: x, y: frame.midY)
                        }
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private struct Surface {
        var frame: CGRect
        var dividers: [CGFloat] = []
        let controls: Bool
    }

    private func surfaces(anchors: [DashboardWidget: Anchor<CGRect>], proxy: GeometryProxy) -> [Surface] {
        var result: [Surface] = []
        for tile in model.dashboard.tiles {
            guard let anchor = anchors[tile.kind] else { continue }
            let frame = proxy[anchor]
            if tile.kind.isControl, let last = result.last, last.controls,
               abs(last.frame.minY - frame.minY) < 1 {
                let index = result.count - 1
                result[index].dividers.append((last.frame.maxX + frame.minX) / 2)
                result[index].frame = last.frame.union(frame)
            } else {
                result.append(Surface(frame: frame, controls: tile.kind.isControl))
            }
        }
        return result
    }

    @ViewBuilder private var editor: some View {
        if #available(macOS 27.0, *) {
            TileGridLayout(tiles: model.displayedDashboard.tiles) {
                ForEach(model.displayedDashboard.tiles) { tile in card(tile, editing: true) }.reorderable()
            }
            .reorderContainer(for: DashboardTile.self) { move in
                switch move.destination.position {
                case .before(let id): model.dashboardDraft?.move(move.sources, before: id)
                case .end: model.dashboardDraft?.move(move.sources, before: nil)
                @unknown default: break
                }
            }
        } else {
            TileGridLayout(tiles: model.displayedDashboard.tiles) {
                ForEach(model.displayedDashboard.tiles) { tile in
                    card(tile, editing: true).draggable(TileDrag(kind: tile.kind))
                        .dropDestination(for: TileDrag.self) { items, _ in
                            guard let item = items.first, item.kind != tile.kind else { return false }
                            model.dashboardDraft?.move(item.kind, onto: tile.kind)
                            return true
                        }
                        .layoutValue(key: TileSpan.self, value: tile.size == .wide ? 2 : 1)
                }
            }
        }
    }

    private func card(_ tile: DashboardTile, editing: Bool) -> some View {
        VStack(alignment: .leading, spacing: tile.kind.isControl ? 10 : 14) {
            HStack(spacing: 8) {
                Text(tile.kind.title).font(tile.kind.isControl ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(Color.primary.opacity(tile.kind.isControl ? 0.78 : 1))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if tile.kind == .usage && !editing {
                    UsagePeriodSwitch(allTime: $allTime)
                }
                if editing {
                    Color.clear.frame(width: 24, height: 26)
                        .anchorPreference(key: EditAnchors.self, value: .bounds) { .init(handles: [tile.kind: $0]) }
                    Menu {
                        Button("前移") { model.dashboardDraft?.step(tile.kind, by: -1) }
                            .disabled(model.displayedDashboard.tiles.first?.kind == tile.kind)
                        Button("后移") { model.dashboardDraft?.step(tile.kind, by: 1) }
                            .disabled(model.displayedDashboard.tiles.last?.kind == tile.kind)
                        Divider()
                        Button(tile.size == .wide ? "改为紧凑" : "改为宽幅") {
                            model.dashboardDraft?.resize(tile.kind, to: tile.size == .wide ? .compact : .wide)
                        }
                        Button("移除小组件") { model.dashboardDraft?.remove(tile.kind) }
                    } label: { Label("编辑" + tile.kind.title, systemImage: "ellipsis.circle") }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                }
            }
            DashboardCardContent(tile: tile, model: model, allTime: allTime).disabled(editing)
                .allowsHitTesting(!editing)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if editing {
                RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(hoverTarget == tile.kind ? Color.accentColor : .primary.opacity(0.23)) }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .contain)
        .transformAnchorPreference(key: EditAnchors.self, value: .bounds) { anchors, bounds in
            anchors.cards[tile.kind] = bounds
        }
        .layoutValue(key: TileSpan.self, value: tile.size == .wide ? 2 : 1)
    }
}

struct WidgetCatalog: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加小组件").font(.title2.bold())
            ForEach(DashboardWidget.allCases, id: \.self) { kind in
                HStack {
                    Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.headline)
                        Text(kind.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let added = model.displayedDashboard.contains(kind)
                    Button(added ? "已添加" : "添加") { model.dashboardDraft?.add(kind) }
                        .disabled(added).accessibilityLabel((added ? "已添加" : "添加") + kind.title)
                }
                Divider()
            }
            HStack {
                Button("恢复默认布局") { model.dashboardDraft = DashboardLayout() }
                Spacer()
                Button("返回编辑") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 380)
    }
}
