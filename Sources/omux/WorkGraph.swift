import SwiftUI

/// The month as a graph, in the manner of a notes app's graph view: a node for each project,
/// sized by its time, with its sessions around it. Nodes push apart and links pull together
/// until it settles; nodes can be dragged, the canvas panned and pinched.
@MainActor
final class GraphLayout: ObservableObject {
    enum Kind { case project, session }

    struct Node {
        let id: String
        let kind: Kind
        let label: String
        let color: Color
        let radius: CGFloat
        var position: CGPoint
        var velocity = CGVector.zero
        var pinned = false
    }

    private(set) var nodes: [Node] = []
    private(set) var links: [(Int, Int)] = []
    /// Each node's neighbours, for highlighting.
    private(set) var neighbours: [Set<Int>] = []
    private var index: [String: Int] = [:]
    /// Bumped each simulation step to redraw.
    @Published private(set) var frame = 0
    private var alpha: CGFloat = 0
    private var runner: Task<Void, Never>?

    func node(_ id: String) -> Int? { index[id] }

    /// New nodes for the month; ones already on screen keep their place.
    func set(_ projects: [StatsProject]) {
        let old = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        var nodes: [Node] = []
        var links: [(Int, Int)] = []
        let count = max(projects.count, 1)
        for (i, project) in projects.enumerated() {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            let home = old["p:" + project.id] ?? CGPoint(x: cos(angle) * 160, y: sin(angle) * 120)
            let hours = project.total / 3600
            nodes.append(Node(id: "p:" + project.id, kind: .project, label: project.name, color: project.color,
                              radius: min(26, 9 + CGFloat(sqrt(hours)) * 3.2), position: home))
            let hub = nodes.count - 1
            for slice in project.sessions {
                let minutes = slice.time / 60
                let jitter = CGPoint(x: .random(in: -40...40), y: .random(in: -40...40))
                nodes.append(Node(id: "s:" + slice.id, kind: .session, label: slice.session.title, color: project.color,
                                  radius: min(9, 3 + CGFloat(sqrt(minutes)) / 2.2),
                                  position: old["s:" + slice.id] ?? CGPoint(x: home.x + jitter.x, y: home.y + jitter.y)))
                links.append((hub, nodes.count - 1))
            }
        }
        self.nodes = nodes
        self.links = links
        index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var neighbours = Array(repeating: Set<Int>(), count: nodes.count)
        for (a, b) in links { neighbours[a].insert(b); neighbours[b].insert(a) }
        self.neighbours = neighbours
        // Settle most of the way at once, so it opens near its shape and eases the rest.
        alpha = 1
        for _ in 0..<80 { step() }
        heat(0.35)
    }

    func heat(_ value: CGFloat = 0.3) {
        alpha = max(alpha, value)
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, self.alpha > 0.008, !Task.isCancelled {
                self.step()
                self.frame &+= 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.runner = nil
        }
    }

    func move(_ i: Int, to point: CGPoint) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].position = point
        nodes[i].velocity = .zero
        nodes[i].pinned = true
        heat(0.25)
        frame &+= 1
    }

    func release(_ i: Int) {
        guard nodes.indices.contains(i) else { return }
        nodes[i].pinned = false
    }

    private func step() {
        let n = nodes.count
        guard n > 0 else { return }
        // Every pair pushes apart, harder up close.
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = nodes[j].position.x - nodes[i].position.x
                var dy = nodes[j].position.y - nodes[i].position.y
                if dx == 0, dy == 0 { dx = .random(in: -1...1); dy = .random(in: -1...1) }
                let distance2 = max(dx * dx + dy * dy, 25)
                let strength = (nodes[i].kind == .project && nodes[j].kind == .project ? 5200 : 700) * alpha / distance2
                let distance = distance2.squareRoot()
                let fx = dx / distance * strength, fy = dy / distance * strength
                nodes[i].velocity.dx -= fx; nodes[i].velocity.dy -= fy
                nodes[j].velocity.dx += fx; nodes[j].velocity.dy += fy
            }
        }
        // Links pull a session to its project.
        for (a, b) in links {
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
            let rest = 46 + nodes[a].radius + nodes[b].radius
            let pull = (distance - rest) / distance * 0.08 * alpha
            nodes[a].velocity.dx += dx * pull * 0.3; nodes[a].velocity.dy += dy * pull * 0.3
            nodes[b].velocity.dx -= dx * pull; nodes[b].velocity.dy -= dy * pull
        }
        for i in 0..<n {
            // A soft pull to the middle keeps loose projects on screen.
            nodes[i].velocity.dx -= nodes[i].position.x * 0.012 * alpha
            nodes[i].velocity.dy -= nodes[i].position.y * 0.016 * alpha
            nodes[i].velocity.dx *= 0.62
            nodes[i].velocity.dy *= 0.62
            guard !nodes[i].pinned else { nodes[i].velocity = .zero; continue }
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }
        alpha *= 0.982
    }
}

struct WorkGraph: View {
    @ObservedObject var layout: GraphLayout
    var selection: StatsSelection?
    /// Nodes worked on during the picked day; the rest fade.
    var active: Set<String>? = nil
    /// A node pointed at elsewhere on the page.
    var pointed: String? = nil
    var select: (StatsSelection?) -> Void

    @State private var hovered: Int?
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panStart: CGSize?
    @State private var dragged: Int?
    @GestureState private var pinch: CGFloat = 1

    private var scale: CGFloat { zoom * pinch }

    private var selectedNode: Int? {
        switch selection {
        case .project(let id): return layout.node("p:" + id)
        case .session(let id): return layout.node("s:" + id)
        case nil: return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, size in draw(&context, size: size) }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let hit = hitTest(point, size: size)
                        if hit != hovered { hovered = hit }
                        if hit != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    case .ended:
                        hovered = nil
                        NSCursor.arrow.set()
                    }
                }
                .gesture(drag(size: size))
                .simultaneousGesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = clampZoom(zoom * value.magnification) })
        }
        .overlay(alignment: .bottomTrailing) { controls }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = clampZoom(zoom / 1.25) } } label: { Image(systemName: "minus") }
            Divider().frame(height: 14)
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero } } label: { Image(systemName: "scope") }
                .help("Fit")
            Divider().frame(height: 14)
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = clampZoom(zoom * 1.25) } } label: { Image(systemName: "plus") }
        }
        .buttonStyle(GraphButtonStyle())
        .background(StatsStyle.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StatsStyle.border))
        .padding(10)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat { min(3, max(0.35, value)) }

    private func toScreen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + pan.width + p.x * scale, y: size.height / 2 + pan.height + p.y * scale)
    }

    private func toGraph(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - pan.width) / scale, y: (p.y - size.height / 2 - pan.height) / scale)
    }

    private func hitTest(_ point: CGPoint, size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, node) in layout.nodes.enumerated() {
            let p = toScreen(node.position, size)
            let distance = hypot(p.x - point.x, p.y - point.y)
            if distance <= max(node.radius * scale, 6) + 3, distance < (best?.1 ?? .infinity) { best = (i, distance) }
        }
        return best?.0
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragged == nil, panStart == nil {
                    if let hit = hitTest(value.startLocation, size: size) { dragged = hit } else { panStart = pan }
                }
                let moved = hypot(value.translation.width, value.translation.height) > 3
                if let dragged, moved {
                    layout.move(dragged, to: toGraph(value.location, size))
                } else if let panStart {
                    pan = CGSize(width: panStart.width + value.translation.width, height: panStart.height + value.translation.height)
                }
            }
            .onEnded { value in
                let click = hypot(value.translation.width, value.translation.height) <= 3
                if let dragged {
                    layout.release(dragged)
                    if click { pick(dragged) }
                } else if click {
                    select(nil)
                }
                dragged = nil
                panStart = nil
            }
    }

    private func pick(_ i: Int) {
        let node = layout.nodes[i]
        let id = String(node.id.dropFirst(2))
        let choice: StatsSelection = node.kind == .project ? .project(id) : .session(id)
        select(choice == selection ? nil : choice)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let nodes = layout.nodes
        guard !nodes.isEmpty else { return }
        // What's under the pointer, or else what's picked, lights up with its neighbours.
        let focus = hovered ?? pointed.flatMap { layout.node($0) } ?? selectedNode
        var lit = Set<Int>()
        if let focus, layout.neighbours.indices.contains(focus) {
            lit = layout.neighbours[focus].union([focus])
            // A project lights its sessions; a session its project and that project's sessions.
            if nodes[focus].kind == .session, let hub = layout.neighbours[focus].first { lit.formUnion(layout.neighbours[hub]) }
        }
        if let active {
            // The day's work, with what's picked or pointed at inside it.
            let day = Set(nodes.indices.filter { active.contains(nodes[$0].id) })
            lit = lit.isEmpty ? day : lit.intersection(day).union(focus.map { [$0] } ?? [])
        }
        let dimmed = !lit.isEmpty || active != nil

        for (a, b) in layout.links {
            var path = Path()
            path.move(to: toScreen(nodes[a].position, size))
            path.addLine(to: toScreen(nodes[b].position, size))
            let on = lit.contains(a) && lit.contains(b)
            context.stroke(path, with: .color(on ? nodes[a].color.opacity(0.55) : Color(white: 0.6).opacity(dimmed ? 0.12 : 0.35)),
                           lineWidth: on ? 1.3 : 0.8)
        }
        // Sessions first, so projects sit on top.
        let order = nodes.indices.sorted { (nodes[$0].kind == .project ? 1 : 0) < (nodes[$1].kind == .project ? 1 : 0) }
        for i in order {
            let node = nodes[i]
            let p = toScreen(node.position, size)
            let r = max(node.radius * scale, 2.5)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let faded = dimmed && !lit.contains(i)
            let fill: Color = node.kind == .project ? node.color : node.color.opacity(0.55)
            context.fill(Path(ellipseIn: rect), with: .color(faded ? fill.opacity(0.18) : fill))
            if i == selectedNode {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3.5, dy: -3.5)), with: .color(node.color), lineWidth: 2)
            }
            let showLabel = node.kind == .project || i == hovered || i == selectedNode || (lit.contains(i) && nodes.count < 60) || scale >= 1.8
            guard showLabel, !(faded && node.kind == .session) else { continue }
            let label = node.label.count > 34 ? String(node.label.prefix(33)) + "…" : node.label
            let text = Text(label)
                .font(.system(size: node.kind == .project ? 11.5 : 10, weight: node.kind == .project ? .semibold : .regular))
                .foregroundColor(faded ? StatsStyle.faint.opacity(0.5) : node.kind == .project ? StatsStyle.ink : StatsStyle.muted)
            context.draw(text, at: CGPoint(x: p.x, y: p.y + r + 4), anchor: .top)
        }
    }
}

private struct GraphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StatsStyle.muted)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
