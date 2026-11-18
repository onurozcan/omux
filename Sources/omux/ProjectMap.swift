import SwiftUI

/// The month as a grid: a row for each project, a column for each day, and each cell as deep
/// in the project's color as the hours worked there that day. Clicking a project picks it;
/// clicking a cell picks that project and that day for the whole page.
struct ProjectMap: View {
    @ObservedObject var model: StatsModel
    /// The cell under the pointer: only this view redraws while it moves.
    @State private var hover: Cell?

    struct Cell: Equatable {
        let project: String
        let day: Date
    }

    private let rowHeight: CGFloat = 26
    private let headerHeight: CGFloat = 30
    private let labelWidth: CGFloat = 190

    var body: some View {
        let projects = model.snapshot.projects
        let picked = model.selectedProjectID
        VStack(alignment: .leading, spacing: 10) {
            caption
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: headerHeight)
                        ForEach(projects) { project in
                            label(project, picked: picked == project.id, faded: picked != nil && picked != project.id)
                        }
                    }
                    .frame(width: labelWidth)
                    grid(projects: projects, picked: picked)
                        .frame(height: headerHeight + rowHeight * CGFloat(projects.count))
                }
            }
            .scrollIndicators(.never)
        }
        .padding(14)
    }

    private var caption: some View {
        HStack(spacing: 8) {
            Text("Where the month went").font(.system(size: 12, weight: .semibold))
            Spacer()
            if let hover, let project = model.snapshot.project(hover.project) {
                let time = project.perDay[hover.day] ?? 0
                HStack(spacing: 5) {
                    Circle().fill(project.color).frame(width: 7, height: 7)
                    Text(project.name).fontWeight(.medium)
                    Text("· \(hover.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                    if time > 0 {
                        Text("· \(StatsStyle.duration(time)) · \(sessions(of: project, on: hover.day)) sessions")
                    } else {
                        Text("· nothing")
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(StatsStyle.muted)
            } else {
                Text("click a project or a day")
                    .font(.system(size: 11))
                    .foregroundStyle(StatsStyle.faint)
            }
        }
        .frame(height: 16)
    }

    private func label(_ project: StatsProject, picked: Bool, faded: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { model.selection = picked ? nil : .project(project.id) }
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(project.color).frame(width: 8, height: 8)
                Text(project.name)
                    .font(.system(size: 12, weight: picked ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(StatsStyle.duration(project.total))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            .padding(.horizontal, 7)
            .frame(height: rowHeight - 2)
            .background(picked ? project.color.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(faded ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: rowHeight)
        .help(picked ? "Show every project" : "Show only \(project.name)")
    }

    private func grid(projects: [StatsProject], picked: String?) -> some View {
        let days = model.snapshot.days
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let peak = max(projects.flatMap { $0.perDay.values }.max() ?? 1, 1)
        let sessionDays = pickedSessionDays()
        let selectedDay = model.day
        let hover = hover
        return Canvas { context, size in
            guard !days.isEmpty else { return }
            let width = size.width / CGFloat(days.count)
            for (i, day) in days.enumerated() {
                let x = CGFloat(i) * width
                let column = CGRect(x: x, y: 0, width: width, height: size.height)
                if day == selectedDay {
                    context.fill(Path(roundedRect: column, cornerRadius: 4), with: .color(StatsStyle.accent.opacity(0.14)))
                } else if calendar.isDateInWeekend(day) {
                    context.fill(Path(column), with: .color(StatsStyle.wash.opacity(0.6)))
                }
                let isToday = day == today
                context.draw(Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 8.5))
                                .foregroundColor(StatsStyle.faint),
                             at: CGPoint(x: x + width / 2, y: 8))
                context.draw(Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 9.5, weight: isToday ? .bold : .regular).monospacedDigit())
                                .foregroundColor(isToday ? StatsStyle.accent : StatsStyle.muted),
                             at: CGPoint(x: x + width / 2, y: 20))
            }
            for (row, project) in projects.enumerated() {
                let y = headerHeight + CGFloat(row) * rowHeight
                let faded = picked != nil && picked != project.id
                for (i, day) in days.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * width, y: y, width: width, height: rowHeight).insetBy(dx: 1.5, dy: 2.5)
                    let seconds = project.perDay[day] ?? 0
                    let shape = Path(roundedRect: rect, cornerRadius: 3)
                    if seconds > 0 {
                        // Square root, so an hour still shows next to a ten-hour day.
                        let depth = 0.22 + 0.78 * (seconds / peak).squareRoot()
                        context.fill(shape, with: .color(project.color.opacity(depth * (faded ? 0.3 : 1))))
                    } else {
                        context.fill(shape, with: .color(StatsStyle.wash.opacity(faded ? 0.4 : 0.8)))
                    }
                    if picked == project.id, sessionDays.contains(day) {
                        context.stroke(shape, with: .color(StatsStyle.ink.opacity(0.85)), lineWidth: 1.5)
                    }
                    if hover == Cell(project: project.id, day: day) {
                        context.stroke(shape, with: .color(StatsStyle.ink.opacity(0.6)), lineWidth: 1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): self.hover = cell(at: point, size: geo.size, projects: projects)
                        case .ended: self.hover = nil
                        }
                    }
                    .onTapGesture { point in
                        guard let cell = cell(at: point, size: geo.size, projects: projects) else { return }
                        pick(cell)
                    }
            }
        }
    }

    private func cell(at point: CGPoint, size: CGSize, projects: [StatsProject]) -> Cell? {
        let days = model.snapshot.days
        guard !days.isEmpty, point.y >= headerHeight else { return nil }
        let row = Int((point.y - headerHeight) / rowHeight)
        let column = Int(point.x / (size.width / CGFloat(days.count)))
        guard projects.indices.contains(row), days.indices.contains(column) else { return nil }
        return Cell(project: projects[row].id, day: days[column])
    }

    /// A worked cell picks its project and its day; clicking it again lets go of the day.
    private func pick(_ cell: Cell) {
        guard let project = model.snapshot.project(cell.project), (project.perDay[cell.day] ?? 0) > 0 else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            let same = model.day == cell.day && model.selectedProjectID == cell.project
            if case .session(let id) = model.selection, model.snapshot.slice(id)?.0.id == cell.project {
                // Keep a picked session: its days are outlined in this row.
            } else {
                model.selection = .project(cell.project)
            }
            model.day = same ? nil : cell.day
        }
    }

    /// The days the picked session ran on, outlined in its project's row.
    private func pickedSessionDays() -> Set<Date> {
        guard case .session(let id) = model.selection, let (_, slice) = model.snapshot.slice(id) else { return [] }
        return Set(WorkStats.perDay(slice.spans).keys)
    }

    private func sessions(of project: StatsProject, on day: Date) -> Int {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return 0 }
        return project.sessions.filter { $0.spans.contains { $0.end > day && $0.start < next } }.count
    }
}
