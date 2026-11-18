import Charts
import SwiftUI

/// The statistics window: what was worked on in a month, project by project and session by
/// session, from Claude Code's conversations. A graph of projects and their sessions with the
/// picked one's details beside it, the hours of each day, and below, a log day by day.
struct StatsView: View {
    @ObservedObject private var model = StatsModel.shared
    @StateObject private var layout = GraphLayout()

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    tiles
                    HStack(alignment: .top, spacing: 14) {
                        card {
                            WorkGraph(layout: layout, selection: model.selection) { model.selection = $0 }
                                .overlay { if model.snapshot.projects.isEmpty { empty } }
                        }
                        .frame(height: 440)
                        card { StatsDetail(model: model) }
                            .frame(width: 340, height: 440)
                    }
                    card { DailyChart(model: model) }
                        .frame(height: 330)
                    DailyLog(model: model)
                }
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 32)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.focusedDay) { _, day in
                guard let day else { return }
                withAnimation(.easeInOut(duration: 0.3)) { reader.scrollTo(day, anchor: .top) }
            }
        }
        .background(StatsStyle.background)
        .foregroundStyle(StatsStyle.ink)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .onAppear { model.reload(); layout.set(model.snapshot.projects) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.reload() }
        .onChange(of: model.snapshot.projects.map(\.id)) { _, _ in layout.set(model.snapshot.projects) }
        .onChange(of: model.snapshot.total) { _, _ in layout.set(model.snapshot.projects) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: model.loaded ? "circle.dotted" : "hourglass")
                .font(.system(size: 22))
                .foregroundStyle(StatsStyle.faint)
            Text(model.loaded ? "No Claude Code sessions this month" : "Reading conversations…")
                .font(.system(size: 12))
                .foregroundStyle(StatsStyle.muted)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Statistics").font(.system(size: 24, weight: .bold))
                Text("What you built, project by project and session by session, from your Claude Code conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(StatsStyle.muted)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            HStack(spacing: 0) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                Divider().frame(height: 30)
                Text(model.month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 130)
                Divider().frame(height: 30)
                Button { model.step(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                    .disabled(model.isCurrentMonth)
            }
            .buttonStyle(.plain)
            .background(StatsStyle.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StatsStyle.border))
            Button("Current month") { model.month = StatsModel.startOfMonth(Date()) }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.isCurrentMonth)
            Button { model.reload(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(OutlineButtonStyle())
                .help("Read the conversations again")
        }
    }

    private var tiles: some View {
        let snapshot = model.snapshot
        let activeDays = snapshot.perDay.values.filter { $0 >= 60 }.count
        let sessions = snapshot.projects.reduce(0) { $0 + $1.sessions.count }
        return HStack(spacing: 14) {
            StatTile(title: "Active time", value: StatsStyle.duration(snapshot.total), note: "\(StatsStyle.hours(snapshot.total)) hours")
            StatTile(title: "Active days", value: "\(activeDays)",
                     note: activeDays > 0 ? "\(StatsStyle.duration(snapshot.total / Double(activeDays))) a day" : "—")
            StatTile(title: "Projects", value: "\(snapshot.projects.count)", note: snapshot.projects.first.map { "Most: \($0.name)" } ?? "—")
            StatTile(title: "Sessions", value: "\(sessions)", note: "\(snapshot.projects.reduce(0) { $0 + $1.sessions.reduce(0) { $0 + $1.session.prompts.count } }) requests")
            StatTile(title: "Commits", value: "\(model.commits.count)", note: "in project repositories")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StatsStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StatsStyle.border))
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(StatsStyle.faint)
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(StatsStyle.muted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatsStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StatsStyle.border))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(enabled ? StatsStyle.accent : StatsStyle.faint)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(configuration.isPressed ? StatsStyle.wash : StatsStyle.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(enabled ? StatsStyle.accent.opacity(0.5) : StatsStyle.border))
            .contentShape(Rectangle())
    }
}

// MARK: - Details beside the graph

private struct StatsDetail: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.selection {
                case .project(let id):
                    if let project = model.snapshot.project(id) { ProjectDetail(model: model, project: project) }
                case .session(let id):
                    if let (project, slice) = model.snapshot.slice(id) { SessionDetail(model: model, project: project, slice: slice) }
                case nil:
                    overview
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Projects this month")
            if model.snapshot.projects.isEmpty {
                Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(StatsStyle.muted)
            }
            let top = model.snapshot.projects.first?.total ?? 1
            ForEach(model.snapshot.projects) { project in
                Button { model.selection = .project(project.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Circle().fill(project.color).frame(width: 8, height: 8)
                            Text(project.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(StatsStyle.duration(project.total))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(StatsStyle.muted)
                        }
                        GeometryReader { geo in
                            Capsule().fill(project.color.opacity(0.75))
                                .frame(width: max(3, geo.size.width * project.total / max(top, 1)))
                        }
                        .frame(height: 3)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Click a node to see what was done in it. Drag nodes, pinch to zoom.")
                .font(.system(size: 11))
                .foregroundStyle(StatsStyle.faint)
                .padding(.top, 6)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(StatsStyle.faint)
    }
}

private struct BackButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(StatsStyle.accent)
    }
}

private struct ProjectDetail: View {
    @ObservedObject var model: StatsModel
    let project: StatsProject

    var body: some View {
        let commits = model.commits(in: project.id)
        VStack(alignment: .leading, spacing: 14) {
            BackButton(title: "All projects") { model.selection = nil }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(project.color).frame(width: 10, height: 10)
                    Text(project.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                }
                Text(project.id.tildeAbbreviated)
                    .font(.system(size: 11))
                    .foregroundStyle(StatsStyle.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(StatsStyle.duration(project.total)) · \(project.sessions.count) sessions · \(commits.count) commits")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            SectionTitle(text: "Sessions")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(project.sessions) { slice in
                    Button { model.selection = .session(slice.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.session.title).font(.system(size: 12.5)).lineLimit(2)
                                Text(slice.session.start.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(StatsStyle.faint)
                            }
                            Spacer(minLength: 4)
                            Text(StatsStyle.duration(slice.time))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(StatsStyle.muted)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            if !commits.isEmpty {
                SectionTitle(text: "Commits")
                CommitList(commits: Array(commits.prefix(30)))
            }
        }
    }
}

private struct SessionDetail: View {
    @ObservedObject var model: StatsModel
    let project: StatsProject
    let slice: StatsSessionSlice

    var body: some View {
        let session = slice.session
        // Commits made while the session was going, give or take a few minutes.
        let commits = model.commits(in: project.id).filter { StatsStyle.during($0, session.spans) }
        VStack(alignment: .leading, spacing: 14) {
            BackButton(title: project.name) { model.selection = .project(project.id) }
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.system(size: 15, weight: .bold)).lineLimit(3)
                HStack(spacing: 6) {
                    Circle().fill(project.color).frame(width: 7, height: 7)
                    Text(project.name)
                    if let branch = session.branch {
                        Text("·")
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch).lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(StatsStyle.muted)
                Text("\(session.start.formatted(.dateTime.day().month(.abbreviated).hour().minute())) – \(StatsStyle.time(session.end)) · \(StatsStyle.duration(slice.time)) active")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            Button { model.open(session) } label: { Label("Open in omux", systemImage: "arrow.up.forward.app") }
                .buttonStyle(OutlineButtonStyle())
            if !session.prompts.isEmpty {
                SectionTitle(text: "What was asked")
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(session.prompts.enumerated()), id: \.offset) { _, prompt in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(StatsStyle.time(prompt.date))
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(StatsStyle.faint)
                                .frame(width: 40, alignment: .leading)
                            Text(prompt.text)
                                .font(.system(size: 12))
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !commits.isEmpty {
                SectionTitle(text: "Commits")
                CommitList(commits: commits)
            }
        }
    }
}

private struct CommitList: View {
    let commits: [WorkCommit]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(commits) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(String(commit.id.prefix(7)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(StatsStyle.accent)
                    Text(commit.subject).font(.system(size: 12)).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Hours a day

private struct DailyChart: View {
    @ObservedObject var model: StatsModel
    /// A working day, as a time sheet expects.
    private let target: Double = 8

    private var project: StatsProject? { model.selectedProjectID.flatMap { model.snapshot.project($0) } }
    private var perDay: [Date: TimeInterval] { project?.perDay ?? model.snapshot.perDay }
    private var total: TimeInterval { project?.total ?? model.snapshot.total }
    private var color: Color { project?.color ?? StatsStyle.bar }

    var body: some View {
        let calendar = Calendar.current
        let days = model.snapshot.days
        let required = Double(days.filter { !calendar.isDateInWeekend($0) }.count) * target
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.map { "Hours on \($0.name)" } ?? "Hours a day")
                    .font(.system(size: 14, weight: .semibold))
                if project != nil {
                    Button("Show all") { model.selection = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(StatsStyle.accent)
                }
                Spacer()
                Text("Total time: \(StatsStyle.hours(total)) h")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            Chart {
                ForEach(days.filter { calendar.isDateInWeekend($0) }, id: \.self) { day in
                    RectangleMark(xStart: .value("Day", day), xEnd: .value("Day", day.addingTimeInterval(86400)))
                        .foregroundStyle(StatsStyle.wash)
                }
                ForEach(days, id: \.self) { day in
                    let hours = (perDay[day] ?? 0) / 3600
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Hours", hours), width: .ratio(0.55))
                        .foregroundStyle(model.focusedDay == day ? color.opacity(1) : color.opacity(0.85))
                        .cornerRadius(2)
                        .annotation(position: .top, spacing: 3) {
                            if hours >= 0.05 {
                                Text(StatsStyle.hours(hours * 3600))
                                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(StatsStyle.muted)
                            }
                        }
                }
                ForEach(days, id: \.self) { day in
                    LineMark(x: .value("Day", day.addingTimeInterval(43200)), y: .value("Target", calendar.isDateInWeekend(day) ? 0 : target),
                             series: .value("Series", "Target"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StatsStyle.target)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .chartXScale(domain: (days.first ?? model.month)...(model.monthEnd))
            .chartYScale(domain: 0...max(10, ((perDay.values.max() ?? 0) / 3600).rounded(.up) + 1))
            .chartYAxisLabel("Hours", position: .leading)
            .chartXAxis {
                AxisMarks(values: days.map { $0.addingTimeInterval(43200) }) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            VStack(spacing: 1) {
                                Text(date.formatted(.dateTime.weekday(.narrow))).foregroundStyle(StatsStyle.ink)
                                Text(date.formatted(.dateTime.day())).foregroundStyle(StatsStyle.faint)
                            }
                            .font(.system(size: 9.5))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(StatsStyle.border)
                    AxisValueLabel().foregroundStyle(StatsStyle.muted)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geo[frame].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            let day = calendar.startOfDay(for: date)
                            model.focusedDay = (perDay[day] ?? 0) > 0 ? day : nil
                        }
                }
            }
            HStack(spacing: 18) {
                Legend(swatch: AnyView(Circle().fill(color).frame(width: 9, height: 9)), title: "Active", value: "\(StatsStyle.hours(total)) h")
                Legend(swatch: AnyView(Capsule().fill(StatsStyle.target).frame(width: 14, height: 2)), title: "Target", value: "\(StatsStyle.hours(required * 3600)) h")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }
}

private struct Legend: View {
    let swatch: AnyView
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            swatch
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(value).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(StatsStyle.muted)
        }
    }
}

// MARK: - The log, day by day

private struct DailyLog: View {
    @ObservedObject var model: StatsModel
    @State private var open: Set<Date> = []
    @State private var opened = false

    private struct Entry: Identifiable {
        let project: StatsProject
        let slice: StatsSessionSlice
        let spans: [WorkSpan]
        let time: TimeInterval
        let prompts: [WorkPrompt]
        var id: String { slice.id }

        /// How far the commit is from this session's work; nil when it can't be this session's.
        func distance(to commit: WorkCommit) -> TimeInterval? {
            guard commit.repository == project.id, StatsStyle.during(commit, spans) else { return nil }
            return spans.map { commit.date < $0.start ? $0.start.timeIntervalSince(commit.date) : max(0, commit.date.timeIntervalSince($0.end)) }.min()
        }
    }

    private struct Day: Identifiable {
        let date: Date
        let entries: [Entry]
        let time: TimeInterval
        let commits: [WorkCommit]
        var id: Date { date }

        /// Each commit goes to the one session it was nearest; the rest are the day's own.
        var owned: (byEntry: [String: [WorkCommit]], loose: [WorkCommit]) {
            var byEntry: [String: [WorkCommit]] = [:]
            var loose: [WorkCommit] = []
            for commit in commits {
                let best = entries.compactMap { entry in entry.distance(to: commit).map { (entry.id, $0) } }.min { $0.1 < $1.1 }
                if let best { byEntry[best.0, default: []].append(commit) } else { loose.append(commit) }
            }
            return (byEntry, loose)
        }
        var start: Date { entries.compactMap { $0.spans.first?.start }.min() ?? date }
        var end: Date { entries.compactMap { $0.spans.last?.end }.max() ?? date }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let projectID = model.selectedProjectID
        let projects = model.snapshot.projects.filter { projectID == nil || $0.id == projectID }
        let folders = Set(projects.map(\.id))
        return model.snapshot.days.reversed().compactMap { day in
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            var entries: [Entry] = []
            for project in projects {
                for slice in project.sessions {
                    let spans = WorkStats.clip(slice.spans, from: day, to: next)
                    guard !spans.isEmpty else { continue }
                    let prompts = slice.session.prompts.filter { $0.date >= day && $0.date < next }
                    entries.append(Entry(project: project, slice: slice, spans: spans,
                                         time: spans.reduce(0) { $0 + $1.duration }, prompts: prompts))
                }
            }
            guard !entries.isEmpty else { return nil }
            let union = WorkStats.union(entries.flatMap(\.spans))
            let commits = model.commits.filter { $0.date >= day && $0.date < next && folders.contains($0.repository) }
            return Day(date: day, entries: entries.sorted { ($0.spans.first?.start ?? day) < ($1.spans.first?.start ?? day) },
                       time: union.reduce(0) { $0 + $1.duration }, commits: commits)
        }
    }

    var body: some View {
        let days = days
        let weeks = Dictionary(grouping: days) { Calendar.current.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daily log").font(.system(size: 20, weight: .bold))
                if let id = model.selectedProjectID, let project = model.snapshot.project(id) {
                    Text(project.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(project.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(project.color.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button(open.count == days.count && !days.isEmpty ? "Collapse all" : "Expand all") {
                    open = open.count == days.count ? [] : Set(days.map(\.date))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StatsStyle.accent)
            }
            if days.isEmpty {
                Text(model.loaded ? "No work logged this month." : "Reading conversations…")
                    .font(.system(size: 12))
                    .foregroundStyle(StatsStyle.muted)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }
            ForEach(weeks.keys.sorted(by: >), id: \.self) { week in
                let weekDays = weeks[week] ?? []
                VStack(spacing: 0) {
                    HStack {
                        let end = Calendar.current.date(byAdding: .day, value: 6, to: week) ?? week
                        Text("\(week.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(StatsStyle.duration(weekDays.reduce(0) { $0 + $1.time }))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(StatsStyle.wash)
                    ForEach(weekDays) { day in
                        Divider()
                        DayRow(day: day, open: open.contains(day.date), focused: model.focusedDay == day.date,
                               toggle: { if open.contains(day.date) { open.remove(day.date) } else { open.insert(day.date) } },
                               select: { model.selection = .session($0) })
                            .id(day.date)
                    }
                }
                .background(StatsStyle.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(StatsStyle.border))
            }
        }
        .onAppear { openLatest(days) }
        .onChange(of: days.first?.date) { _, _ in openLatest(days) }
        .onChange(of: model.focusedDay) { _, day in if let day { open.insert(day) } }
    }

    /// The most recent day starts open, once.
    private func openLatest(_ days: [Day]) {
        guard !opened, let first = days.first else { return }
        opened = true
        open.insert(first.date)
    }

    private struct DayRow: View {
        let day: Day
        let open: Bool
        let focused: Bool
        let toggle: () -> Void
        let select: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StatsStyle.faint)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 12)
                        Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 170, alignment: .leading)
                        HStack(spacing: -3) {
                            ForEach(Array(Set(day.entries.map(\.project.id))).sorted(), id: \.self) { id in
                                if let project = day.entries.first(where: { $0.project.id == id })?.project {
                                    Circle().fill(project.color).frame(width: 9, height: 9)
                                        .overlay(Circle().stroke(StatsStyle.card, lineWidth: 1.5))
                                }
                            }
                        }
                        Text("\(day.entries.count) session\(day.entries.count == 1 ? "" : "s")" + (day.commits.isEmpty ? "" : " · \(day.commits.count) commit\(day.commits.count == 1 ? "" : "s")"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(StatsStyle.muted)
                        Spacer()
                        Label(StatsStyle.time(day.start), systemImage: "clock")
                            .frame(width: 90, alignment: .leading)
                        Label(StatsStyle.time(day.end), systemImage: "clock")
                            .frame(width: 90, alignment: .leading)
                        Text(StatsStyle.duration(day.time))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(StatsStyle.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(focused ? StatsStyle.accent.opacity(0.06) : .clear)
                if open {
                    let owned = day.owned
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(day.entries) { entry in
                            EntryRow(entry: entry, commits: owned.byEntry[entry.id] ?? [], select: select)
                        }
                        // Commits on the day that no session was going for.
                        let loose = owned.loose
                        if !loose.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                SectionTitle(text: "Other commits")
                                CommitList(commits: loose)
                            }
                            .padding(.leading, 24)
                        }
                    }
                    .padding(.leading, 28)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                    .padding(.top, 2)
                }
            }
        }
    }

    private struct EntryRow: View {
        let entry: Entry
        let commits: [WorkCommit]
        let select: (String) -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(entry.project.color).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.project.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(entry.project.color)
                        Button { select(entry.slice.id) } label: {
                            Text(entry.slice.session.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Show this session")
                        Spacer()
                        Text(entry.spans.map { "\(StatsStyle.time($0.start))–\(StatsStyle.time($0.end))" }.joined(separator: ", "))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(StatsStyle.faint)
                            .lineLimit(1)
                        Text(StatsStyle.duration(entry.time))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(StatsStyle.muted)
                            .frame(width: 60, alignment: .trailing)
                    }
                    ForEach(Array(entry.prompts.prefix(6).enumerated()), id: \.offset) { _, prompt in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(StatsStyle.faint)
                            Text(prompt.text).lineLimit(2).textSelection(.enabled)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(StatsStyle.muted)
                    }
                    if entry.prompts.count > 6 {
                        Text("and \(entry.prompts.count - 6) more")
                            .font(.system(size: 11))
                            .foregroundStyle(StatsStyle.faint)
                    }
                    if !commits.isEmpty { CommitList(commits: commits).padding(.top, 2) }
                }
            }
        }
    }
}
