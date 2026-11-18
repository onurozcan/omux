import SwiftUI

/// Where the tokens went: a box for each project as big as its share of the month's tokens,
/// split into its sessions by theirs. A picked project fills the whole map; a picked day counts
/// only that day's tokens.
struct TokenMap: View {
    @ObservedObject var model: StatsModel
    @State private var hover: Tile?

    /// A drawn box: a project's header or one of its sessions.
    struct Tile: Equatable {
        enum Kind: Equatable { case project, session(String) }
        let project: String
        let kind: Kind
        let rect: CGRect
    }

    private let header: CGFloat = 20

    var body: some View {
        let rows = rows()
        let totals = Dictionary(uniqueKeysWithValues: rows.map { ($0.project.id, $0.total) })
        VStack(alignment: .leading, spacing: 10) {
            caption(total: rows.reduce(0) { $0 + $1.total })
            GeometryReader { geo in
                let tiles = layout(rows, in: CGRect(origin: .zero, size: geo.size))
                Canvas { context, _ in draw(tiles, totals: totals, in: &context) }
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point): hover = tile(at: point, in: tiles)
                                case .ended: hover = nil
                                }
                            }
                            .onTapGesture { point in
                                guard let tile = tile(at: point, in: tiles) else { return }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    switch tile.kind {
                                    case .project:
                                        model.selection = model.selection == .project(tile.project) ? nil : .project(tile.project)
                                    case .session(let id):
                                        model.selection = model.selection == .session(id) ? .project(tile.project) : .session(id)
                                    }
                                }
                            }
                    }
            }
            .overlay { if rows.isEmpty { Text("No tokens here.").font(.system(size: 12)).foregroundStyle(StatsStyle.muted) } }
        }
        .padding(14)
    }

    // MARK: What is counted

    private struct Row {
        let project: StatsProject
        let sessions: [(StatsSessionSlice, Int)]
        var total: Int { sessions.reduce(0) { $0 + $1.1 } }
    }

    /// Projects with their sessions' tokens, biggest first: for the month or the picked day,
    /// and only the picked project when there is one.
    private func rows() -> [Row] {
        let picked = model.selectedProjectID
        let day = model.day
        var result: [Row] = []
        for project in model.snapshot.projects where picked == nil || project.id == picked {
            var sessions: [(StatsSessionSlice, Int)] = []
            for slice in project.sessions {
                let count = day.map { slice.tokens(on: $0).total } ?? slice.tokens.total
                if count > 0 { sessions.append((slice, count)) }
            }
            sessions.sort { $0.1 > $1.1 }
            let row = Row(project: project, sessions: sessions)
            if row.total > 0 { result.append(row) }
        }
        return result.sorted { $0.total > $1.total }
    }

    private func caption(total: Int) -> some View {
        HStack(spacing: 8) {
            Text("Where the tokens went").font(.system(size: 12, weight: .semibold))
            Text(StatsStyle.tokens(total) + (model.day.map { " on \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? " this month"))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(StatsStyle.muted)
            Spacer()
            if let hover { describe(hover) } else {
                Text("box size is tokens · click a project or a session")
                    .font(.system(size: 11))
                    .foregroundStyle(StatsStyle.faint)
            }
        }
        .frame(height: 16)
    }

    @ViewBuilder private func describe(_ tile: Tile) -> some View {
        if let project = model.snapshot.project(tile.project) {
            HStack(spacing: 5) {
                Circle().fill(project.color).frame(width: 7, height: 7)
                switch tile.kind {
                case .project:
                    let tokens = model.day.map { day in project.sessions.reduce(WorkTokens()) { $0 + $1.tokens(on: day) } } ?? project.tokens
                    Text(project.name).fontWeight(.medium)
                    Text("· \(StatsStyle.tokens(tokens.total)) · \(StatsStyle.tokens(tokens.output)) written")
                case .session(let id):
                    if let (_, slice) = model.snapshot.slice(id) {
                        let tokens = model.day.map { slice.tokens(on: $0) } ?? slice.tokens
                        Text(slice.session.title).fontWeight(.medium).lineLimit(1).frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        Text("· \(StatsStyle.tokens(tokens.total)) · \(StatsStyle.duration(slice.time))")
                    }
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(StatsStyle.muted)
            .lineLimit(1)
        }
    }

    // MARK: Laying out

    private func layout(_ rows: [Row], in bounds: CGRect) -> [Tile] {
        var tiles: [Tile] = []
        let boxes = Self.squarify(rows.map { Double($0.total) }, in: bounds)
        for (row, box) in zip(rows, boxes) {
            let box = box.insetBy(dx: 2, dy: 2)
            guard box.width > 2, box.height > 2 else { continue }
            let showHeader = box.height > header * 2 && box.width > 40
            if showHeader { tiles.append(Tile(project: row.project.id, kind: .project, rect: CGRect(x: box.minX, y: box.minY, width: box.width, height: header))) }
            let inner = showHeader ? CGRect(x: box.minX, y: box.minY + header, width: box.width, height: box.height - header) : box
            for ((slice, _), rect) in zip(row.sessions, Self.squarify(row.sessions.map { Double($0.1) }, in: inner)) {
                tiles.append(Tile(project: row.project.id, kind: .session(slice.id), rect: rect))
            }
        }
        return tiles
    }

    private func tile(at point: CGPoint, in tiles: [Tile]) -> Tile? {
        tiles.last { $0.rect.contains(point) }
    }

    /// Boxes for `values` (biggest first) filling `rect`, each as near square as it can be.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let sum = values.reduce(0, +)
        guard sum > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / sum
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var i = 0
        func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
            let total = row.reduce(0, +)
            guard let high = row.max(), let low = row.min(), total > 0, low > 0 else { return .infinity }
            return max(side * side * high / (total * total), total * total / (side * side * low))
        }
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var j = i + 1
            while j < areas.count, worst(areas[i...j], side) <= worst(areas[i..<j], side) { j += 1 }
            let row = areas[i..<j]
            let total = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let width = CGFloat(total / Double(remaining.height))
                var y = remaining.minY
                for area in row {
                    let height = CGFloat(area) / width
                    result.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(total / Double(remaining.width))
                var x = remaining.minX
                for area in row {
                    let width = CGFloat(area) / height
                    result.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            i = j
        }
        return result
    }

    // MARK: Drawing

    private func draw(_ tiles: [Tile], totals: [String: Int], in context: inout GraphicsContext) {
        let pickedSession: String? = { if case .session(let id) = model.selection { return id } else { return nil } }()
        for tile in tiles {
            guard let project = model.snapshot.project(tile.project) else { continue }
            let hovered = hover == tile
            switch tile.kind {
            case .project:
                context.draw(Text(project.name).font(.system(size: 11, weight: .semibold)).foregroundColor(StatsStyle.ink),
                             in: tile.rect.insetBy(dx: 4, dy: 3))
                if tile.rect.width > 160 {
                    let total = totals[project.id] ?? 0
                    context.draw(Text(StatsStyle.tokens(total)).font(.system(size: 10.5).monospacedDigit()).foregroundColor(StatsStyle.muted),
                                 at: CGPoint(x: tile.rect.maxX - 4, y: tile.rect.midY), anchor: .trailing)
                }
            case .session(let id):
                let rect = tile.rect.insetBy(dx: 1, dy: 1)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.width / 3, rect.height / 3))
                let dim = pickedSession != nil && pickedSession != id
                context.fill(shape, with: .color(project.color.opacity(dim ? 0.25 : hovered ? 0.95 : 0.7)))
                if pickedSession == id || hovered {
                    context.stroke(shape, with: .color(StatsStyle.ink.opacity(pickedSession == id ? 0.9 : 0.5)), lineWidth: 1.5)
                }
                if rect.width > 70, rect.height > 30, let (_, slice) = model.snapshot.slice(id) {
                    let tokens = model.day.map { slice.tokens(on: $0).total } ?? slice.tokens.total
                    var text = context
                    text.clip(to: Path(rect))
                    text.draw(Text(slice.session.title).font(.system(size: 10.5, weight: .medium)).foregroundColor(.white),
                              in: CGRect(x: rect.minX + 5, y: rect.minY + 4, width: rect.width - 10, height: max(0, rect.height - 22)))
                    text.draw(Text(StatsStyle.tokens(tokens)).font(.system(size: 10).monospacedDigit()).foregroundColor(.white.opacity(0.8)),
                              at: CGPoint(x: rect.minX + 5, y: rect.maxY - 5), anchor: .bottomLeading)
                }
            }
        }
    }
}
