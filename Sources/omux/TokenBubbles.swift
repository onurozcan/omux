import SwiftUI

/// Where the tokens went, as floating bubbles: a bubble for each project, as big as its tokens,
/// holding a bubble for each of its sessions. Clicking a bubble picks it for the whole page.
struct TokenBubbles: View {
    @ObservedObject var model: StatsModel
    @State private var packing = Packing()
    @State private var hover: String?

    /// Bubbles laid out once for the month, in units the view scales to its size.
    struct Packing: Equatable {
        struct Bubble: Equatable {
            let id: String
            let project: String
            let session: String?
            let title: String
            let tokens: Int
            let color: Color
            var center: CGPoint
            var radius: CGFloat
            let phase: Double
            /// The project's phase: a project's bubbles drift together.
            var group = 0.0
        }
        var bubbles: [Bubble] = []
        var bounds = CGRect.zero
        var key = ""
    }

    /// Bubbles grow slower than their tokens, so one big project leaves room for the rest.
    private static let exponent = 0.4
    /// Projects grow slower still: a small one stays a bubble you can point at.
    private static let projectExponent = 0.28

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption
            GeometryReader { geo in
                let fit = fitting(packing.bounds, in: geo.size)
                let quiet = quietSessions()
                TimelineView(.animation(minimumInterval: 1 / 30, paused: packing.bubbles.isEmpty)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in draw(in: &context, fit: fit, time: time, quiet: quiet) }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover = bubble(at: point, fit: fit)?.id
                    case .ended: hover = nil
                    }
                }
                .onTapGesture { point in
                    guard let bubble = bubble(at: point, fit: fit) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        if let session = bubble.session {
                            model.selection = model.selection == .session(session) ? .project(bubble.project) : .session(session)
                        } else {
                            model.selection = model.selection == .project(bubble.project) ? nil : .project(bubble.project)
                        }
                    }
                }
            }
            .overlay {
                if packing.bubbles.isEmpty {
                    Text(model.loaded ? "No tokens this month." : "Reading conversations…").font(.system(size: 12)).foregroundStyle(StatsStyle.muted)
                }
            }
        }
        .padding(16)
        .onAppear { repack() }
        .onChange(of: model.snapshot.tokens) { _, _ in repack() }
        .onChange(of: model.snapshot.projects.count) { _, _ in repack() }
    }

    private var caption: some View {
        HStack(spacing: 8) {
            Text("Where the tokens went").font(.system(size: 13, weight: .semibold))
            Text("\(StatsStyle.tokens(model.snapshot.tokens.total)) this month")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(StatsStyle.muted)
            Spacer(minLength: 8)
            if let hover, let bubble = packing.bubbles.first(where: { $0.id == hover }) {
                HStack(spacing: 5) {
                    Circle().fill(bubble.color).frame(width: 7, height: 7)
                    Text(bubble.title).fontWeight(.medium).lineLimit(1)
                    Text("· \(StatsStyle.tokens(bubble.tokens))").fixedSize()
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(StatsStyle.muted)
            } else {
                Text("bigger bubble, more tokens").font(.system(size: 11)).foregroundStyle(StatsStyle.faint)
            }
        }
        .frame(height: 18)
    }

    // MARK: Packing

    private func repack() {
        let projects = model.snapshot.projects.filter { $0.tokens.total > 0 }
        let key = "\(model.month.timeIntervalSince1970)|\(model.snapshot.tokens.total)|\(projects.count)"
        guard key != packing.key else { return }
        var result = Packing(key: key)
        // Each project: its sessions packed together, then the group as one circle.
        var groups: [(StatsProject, [Packing.Bubble], CGFloat)] = []
        for project in projects {
            let sessions = project.sessions.filter { $0.tokens.total > 0 }.sorted { $0.tokens.total > $1.tokens.total }
            let radii = sessions.map { CGFloat(pow(Double($0.tokens.total), Self.exponent)) }
            let centers = Self.pack(radii, gap: 0.12 * (radii.first ?? 1) / 4)
            var bubbles = zip(sessions, zip(centers, radii)).map { slice, place in
                Packing.Bubble(id: "s:" + slice.id, project: project.id, session: slice.id, title: slice.session.title,
                               tokens: slice.tokens.total, color: project.color, center: place.0, radius: place.1,
                               phase: Double(abs(slice.id.hashValue % 1000)) / 159)
            }
            let enclosing = bubbles.map { hypot($0.center.x, $0.center.y) + $0.radius }.max() ?? 1
            // The group is drawn as big as the project's own size says, its sessions scaled in.
            let target = CGFloat(pow(Double(project.tokens.total), Self.projectExponent))
            let scale = target / (enclosing * 1.14)
            for i in bubbles.indices {
                bubbles[i].center = CGPoint(x: bubbles[i].center.x * scale, y: bubbles[i].center.y * scale)
                bubbles[i].radius *= scale
            }
            groups.append((project, bubbles, target))
        }
        let centers = Self.pack(groups.map(\.2), gap: (groups.first?.2 ?? 10) * 0.16)
        for ((project, sessions, radius), center) in zip(groups, centers) {
            result.bubbles.append(Packing.Bubble(id: "p:" + project.id, project: project.id, session: nil, title: project.name,
                                                 tokens: project.tokens.total, color: project.color, center: center, radius: radius,
                                                 phase: Double(abs(project.id.hashValue % 1000)) / 159))
            let group = Double(abs(project.id.hashValue % 1000)) / 159
            result.bubbles[result.bubbles.count - 1].group = group
            for var bubble in sessions {
                bubble.group = group
                bubble.center = CGPoint(x: bubble.center.x + center.x, y: bubble.center.y + center.y)
                result.bubbles.append(bubble)
            }
        }
        let projectBubbles = result.bubbles.filter { $0.session == nil }
        let minX = projectBubbles.map { $0.center.x - $0.radius }.min() ?? 0
        let maxX = projectBubbles.map { $0.center.x + $0.radius }.max() ?? 0
        let minY = projectBubbles.map { $0.center.y - $0.radius }.min() ?? 0
        let maxY = projectBubbles.map { $0.center.y + $0.radius }.max() ?? 0
        result.bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        packing = result
    }

    /// Centers for circles of `radii` (biggest first) packed around the origin: each goes to
    /// the free place touching one already placed that is nearest the middle.
    static func pack(_ radii: [CGFloat], gap: CGFloat) -> [CGPoint] {
        var placed: [(CGPoint, CGFloat)] = []
        let angles = (0..<18).map { Double($0) * .pi * 2 / 18 }
        for radius in radii {
            guard !placed.isEmpty else { placed.append((.zero, radius)); continue }
            var best: CGPoint?
            var bestDistance = CGFloat.infinity
            for (center, other) in placed {
                let reach = other + radius + gap
                for angle in angles {
                    let spot = CGPoint(x: center.x + reach * CGFloat(cos(angle)), y: center.y + reach * CGFloat(sin(angle)))
                    let distance = hypot(spot.x, spot.y)
                    guard distance < bestDistance else { continue }
                    if placed.contains(where: { hypot($0.0.x - spot.x, $0.0.y - spot.y) < $0.1 + radius + gap * 0.99 }) { continue }
                    best = spot
                    bestDistance = distance
                }
            }
            placed.append((best ?? .zero, radius))
        }
        return placed.map(\.0)
    }

    // MARK: Drawing

    private struct Fit { let scale: CGFloat; let offset: CGPoint }

    private func fitting(_ bounds: CGRect, in size: CGSize) -> Fit {
        guard bounds.width > 0, bounds.height > 0 else { return Fit(scale: 1, offset: .zero) }
        // Room for the labels above the top bubbles and for drifting.
        let scale = min((size.width - 40) / bounds.width, (size.height - 44) / bounds.height)
        return Fit(scale: scale, offset: CGPoint(x: size.width / 2 - bounds.midX * scale, y: (size.height + 18) / 2 - bounds.midY * scale))
    }

    /// Where a bubble is now: its place, drifting a little.
    private func place(_ bubble: Packing.Bubble, fit: Fit, time: Double) -> (CGPoint, CGFloat) {
        let base = CGPoint(x: bubble.center.x * fit.scale + fit.offset.x, y: bubble.center.y * fit.scale + fit.offset.y)
        let phase = bubble.group
        var x = base.x + CGFloat(sin(time * 0.55 + phase)) * 5
        var y = base.y + CGFloat(cos(time * 0.43 + phase * 1.7)) * 5
        if bubble.session != nil {
            x += CGFloat(sin(time * 0.9 + bubble.phase)) * 1.5
            y += CGFloat(cos(time * 0.8 + bubble.phase * 1.3)) * 1.5
        }
        return (CGPoint(x: x, y: y), bubble.radius * fit.scale)
    }

    private func bubble(at point: CGPoint, fit: Fit) -> Packing.Bubble? {
        let hit = { (b: Packing.Bubble) -> Bool in
            let center = CGPoint(x: b.center.x * fit.scale + fit.offset.x, y: b.center.y * fit.scale + fit.offset.y)
            return hypot(center.x - point.x, center.y - point.y) <= b.radius * fit.scale
        }
        return packing.bubbles.last { $0.session != nil && hit($0) } ?? packing.bubbles.first { $0.session == nil && hit($0) }
    }

    /// Sessions with no tokens on the picked day.
    private func quietSessions() -> Set<String> {
        guard let day = model.day else { return [] }
        return Set(model.snapshot.projects.flatMap(\.sessions).filter { $0.tokens(on: day).total == 0 }.map(\.id))
    }

    private func draw(in context: inout GraphicsContext, fit: Fit, time: Double, quiet: Set<String>) {
        let pickedProject = model.selectedProjectID
        let pickedSession: String? = { if case .session(let id) = model.selection { return id } else { return nil } }()
        var labels: [(Packing.Bubble, CGPoint, CGFloat, Bool)] = []
        for bubble in packing.bubbles {
            let (center, radius) = place(bubble, fit: fit, time: time)
            guard radius > 0.5 else { continue }
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let circle = Path(ellipseIn: rect)
            let faded = pickedProject != nil && pickedProject != bubble.project
            let hovered = hover == bubble.id
            if let session = bubble.session {
                let dim = faded || (pickedSession != nil && pickedSession != session) || quiet.contains(session)
                context.fill(circle, with: .color(bubble.color.opacity(dim ? 0.2 : hovered ? 1 : 0.78)))
                if pickedSession == session || hovered {
                    context.stroke(circle, with: .color(StatsStyle.ink.opacity(pickedSession == session ? 0.95 : 0.6)), lineWidth: 1.5)
                }
                if radius > 30, !dim {
                    let box = rect.insetBy(dx: radius * 0.3, dy: radius * 0.3)
                    context.draw(Text(bubble.title).font(.system(size: min(12, max(9.5, radius / 5)), weight: .semibold)).foregroundColor(.white),
                                 in: CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height - 12))
                    context.draw(Text(StatsStyle.tokens(bubble.tokens)).font(.system(size: 9.5).monospacedDigit()).foregroundColor(.white.opacity(0.8)),
                                 at: CGPoint(x: center.x, y: box.maxY), anchor: .bottom)
                }
            } else {
                context.fill(circle, with: .color(bubble.color.opacity(faded ? 0.04 : hovered ? 0.2 : 0.12)))
                context.stroke(circle, with: .color(bubble.color.opacity(faded ? 0.15 : 0.55)), lineWidth: hovered || pickedProject == bubble.project ? 2 : 1)
                labels.append((bubble, center, radius, faded))
            }
        }
        // Project names above their bubbles, biggest first; one that would cover another's is
        // left out until its bubble is pointed at.
        /// Pointed at or picked: its name shows whatever it covers.
        func shown(_ bubble: Packing.Bubble) -> Bool { hover == bubble.id || pickedProject == bubble.project }
        var taken: [CGRect] = []
        for (bubble, center, radius, faded) in labels.sorted(by: { (shown($0.0) ? 1 : 0, $0.2) > (shown($1.0) ? 1 : 0, $1.2) }) {
            let label = Text("\(bubble.title)  ").font(.system(size: 11.5, weight: .bold)).foregroundColor(StatsStyle.ink.opacity(faded ? 0.35 : 1))
                + Text(StatsStyle.tokens(bubble.tokens)).font(.system(size: 10.5).monospacedDigit()).foregroundColor(StatsStyle.muted)
            let resolved = context.resolve(label)
            let size = resolved.measure(in: CGSize(width: 400, height: 40))
            let anchor = CGPoint(x: center.x, y: center.y - radius - 3)
            let rect = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height).insetBy(dx: -3, dy: -1)
            // Nor one lying on another project's bubble.
            let onOther = labels.contains { other in
                guard other.0.id != bubble.id else { return false }
                let x = min(max(other.1.x, rect.minX), rect.maxX), y = min(max(other.1.y, rect.minY), rect.maxY)
                return hypot(other.1.x - x, other.1.y - y) < other.2
            }
            guard shown(bubble) || (!onOther && !taken.contains(where: { $0.intersects(rect) })) else { continue }
            taken.append(rect)
            context.draw(resolved, at: anchor, anchor: .bottom)
        }
    }
}
