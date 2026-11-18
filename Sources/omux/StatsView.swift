import Charts
import SwiftUI

/// The statistics page, in place of the session: what was worked on in a month, project by
/// project and session by session, from Claude Code's conversations. One picked project or
/// session and one picked day run through all of it: the graph lights them, the chart's bars
/// are each project's share in its graph color, and the log below shows what they hold.
struct StatsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var model = StatsModel.shared
    @StateObject private var layout = GraphLayout()
    let theme: Theme
    @Binding var showSidebar: Bool
    @AppStorage(Prefs.sidebarLayout) private var sidebarLayout = "rail"

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    HStack(alignment: .top, spacing: 14) {
                        WorkGraph(layout: layout, selection: model.selection,
                                  active: model.day.map { model.nodes(on: $0) }, pointed: model.pointed) { model.selection = $0 }
                            .overlay { if model.snapshot.projects.isEmpty { empty } }
                            .overlay(alignment: .topLeading) { graphCaption }
                            .statsCard()
                            .frame(height: 400)
                        StatsDetail(model: model)
                            .statsCard()
                            .frame(width: 320, height: 400)
                    }
                    DailyChart(model: model)
                        .statsCard()
                        .frame(height: 250)
                    WorkLog(model: model)
                }
                .padding(18)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
            .clipped()
        }
        .background(Color(nsColor: theme.background))
        .onAppear { model.reload(); layout.set(model.snapshot.projects) }
        .onChange(of: model.snapshot.projects.map(\.id)) { _, _ in layout.set(model.snapshot.projects) }
        .onChange(of: model.snapshot.total) { _, _ in layout.set(model.snapshot.projects) }
        .onExitCommand { store.showStats = false }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } } label: { Image(systemName: "sidebar.leading") }
                .foregroundStyle(showSidebar ? .primary : .secondary)
            Image(systemName: "chart.bar.xaxis").foregroundStyle(.tertiary)
            Text("Statistics").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            Spacer()
            if model.loading { ProgressView().controlSize(.mini) }
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous month")
            Text(model.month.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 96)
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.isCurrentMonth)
                .help("Next month")
            Button { model.month = StatsModel.startOfMonth(Date()) } label: { Image(systemName: "calendar.badge.clock") }
                .disabled(model.isCurrentMonth)
                .help("This month")
            Button { model.reload(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Read the conversations again")
            Button { store.showStats = false } label: { Image(systemName: "xmark") }
                .help("Back to the session (Esc)")
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.secondary)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.leading, showSidebar ? 0 : sidebarLayout == "rail" ? 68 - ProjectRail.width : 68)
        .frame(height: 28)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var graphCaption: some View {
        HStack(spacing: 6) {
            Text("Projects and sessions").font(.system(size: 12, weight: .semibold))
            if let day = model.day {
                Text("· worked on \(day.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StatsStyle.muted)
            }
        }
        .padding(12)
        .allowsHitTesting(false)
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

    /// The month in five numbers, one strip.
    private var summary: some View {
        let snapshot = model.snapshot
        let activeDays = snapshot.perDay.values.filter { $0 >= 60 }.count
        let sessions = snapshot.projects.reduce(0) { $0 + $1.sessions.count }
        let requests = snapshot.projects.reduce(0) { $0 + $1.sessions.reduce(0) { $0 + $1.session.prompts.count } }
        let items: [(String, String, String)] = [
            ("Active time", StatsStyle.duration(snapshot.total), "\(StatsStyle.hours(snapshot.total)) hours"),
            ("Active days", "\(activeDays)", activeDays > 0 ? "\(StatsStyle.duration(snapshot.total / Double(activeDays))) a day" : "—"),
            ("Projects", "\(snapshot.projects.count)", snapshot.projects.first.map { "most on \($0.name)" } ?? "—"),
            ("Sessions", "\(sessions)", "\(requests) requests"),
            ("Commits", "\(model.commits.count)", "in their repositories"),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(StatsStyle.border).frame(width: 1).padding(.vertical, 12) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(StatsStyle.faint)
                    Text(item.1).font(.system(size: 20, weight: .bold).monospacedDigit())
                    Text(item.2).font(.system(size: 11)).foregroundStyle(StatsStyle.muted).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .statsCard()
    }
}

extension View {
    func statsCard() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StatsStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StatsStyle.border))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? StatsStyle.accent : StatsStyle.faint)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(configuration.isPressed ? StatsStyle.wash : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(enabled ? StatsStyle.accent.opacity(0.5) : StatsStyle.border))
            .contentShape(Rectangle())
    }
}

/// A picked project or day, with a × to let go of it.
private struct FilterChip: View {
    let color: Color
    let title: String
    let clear: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            Button(action: clear) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(StatsStyle.muted)
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .frame(height: 22)
        .background(color.opacity(0.14), in: Capsule())
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Every project's time, for the month or the picked day.
    private var overview: some View {
        let rows: [(StatsProject, TimeInterval)] = {
            guard let day = model.day else { return model.snapshot.projects.map { ($0, $0.total) } }
            return model.snapshot.projects.compactMap { project in project.perDay[day].map { (project, $0) } }.sorted { $0.1 > $1.1 }
        }()
        let top = rows.first?.1 ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: model.day.map { "Projects on \($0.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))" } ?? "Projects this month")
            if rows.isEmpty {
                Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(StatsStyle.muted)
            }
            ForEach(rows, id: \.0.id) { project, time in
                Button { model.selection = .project(project.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Circle().fill(project.color).frame(width: 8, height: 8)
                            Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(StatsStyle.duration(time))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(StatsStyle.muted)
                        }
                        Capsule().fill(project.color.opacity(0.8))
                            .frame(height: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaleEffect(x: max(0.01, time / max(top, 1)), y: 1, anchor: .leading)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { model.pointed = $0 ? "p:" + project.id : nil }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
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
        VStack(alignment: .leading, spacing: 12) {
            BackButton(title: "All projects") { model.selection = nil }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(project.color).frame(width: 10, height: 10)
                    Text(project.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                }
                Text(project.id.tildeAbbreviated)
                    .font(.system(size: 11))
                    .foregroundStyle(StatsStyle.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(StatsStyle.duration(project.total)) · \(project.sessions.count) sessions · \(commits.count) commits")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            SectionTitle(text: "Sessions")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(project.sessions) { slice in
                    Button { model.selection = .session(slice.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.session.title).font(.system(size: 12)).lineLimit(2)
                                Text(slice.session.start.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(StatsStyle.faint)
                            }
                            Spacer(minLength: 4)
                            Text(StatsStyle.duration(slice.time))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(StatsStyle.muted)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { model.pointed = $0 ? "s:" + slice.id : nil }
                    Rectangle().fill(StatsStyle.border).frame(height: 1)
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
        let commits = model.commits(in: project.id).filter { StatsStyle.during($0, session.spans) }
        VStack(alignment: .leading, spacing: 12) {
            BackButton(title: project.name) { model.selection = .project(project.id) }
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.system(size: 14, weight: .bold)).lineLimit(3)
                HStack(spacing: 6) {
                    Circle().fill(project.color).frame(width: 7, height: 7)
                    Text(project.name)
                    if let branch = session.branch {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(StatsStyle.muted)
                Text("\(session.start.formatted(.dateTime.day().month(.abbreviated).hour().minute())) – \(StatsStyle.time(session.end)) · \(StatsStyle.duration(slice.time)) active")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            Button { model.open(session) } label: { Label("Open conversation", systemImage: "arrow.up.forward.app") }
                .buttonStyle(OutlineButtonStyle())
            if !session.prompts.isEmpty {
                SectionTitle(text: "What was asked")
                PromptList(prompts: session.prompts)
            }
            if !commits.isEmpty {
                SectionTitle(text: "Commits")
                CommitList(commits: commits)
            }
        }
    }
}

private struct PromptList: View {
    let prompts: [WorkPrompt]
    var lineLimit = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(StatsStyle.time(prompt.date))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(StatsStyle.faint)
                        .frame(width: 38, alignment: .leading)
                    Text(prompt.text)
                        .font(.system(size: 11.5))
                        .lineLimit(lineLimit)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct CommitList: View {
    let commits: [WorkCommit]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(commits) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(String(commit.id.prefix(7)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(StatsStyle.accent)
                    Text(commit.subject).font(.system(size: 11.5)).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Hours a day, in each project's color

private struct DailyChart: View {
    @ObservedObject var model: StatsModel
    /// A working day, as a time sheet expects.
    private let target: Double = 8

    var body: some View {
        let calendar = Calendar.current
        let days = model.snapshot.days
        let stacked = model.stacked()
        let picked = model.selectedProjectID
        let maxHours = (model.snapshot.perDay.values.max() ?? 0) / 3600
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Hours a day").font(.system(size: 12, weight: .semibold))
                Text("click a day to see it below")
                    .font(.system(size: 11))
                    .foregroundStyle(StatsStyle.faint)
                Spacer()
                HStack(spacing: 5) {
                    Capsule().fill(StatsStyle.target).frame(width: 12, height: 2)
                    Text("8h a weekday").font(.system(size: 11)).foregroundStyle(StatsStyle.muted)
                }
                Text("Total \(StatsStyle.hours(model.snapshot.total)) h")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            Chart {
                ForEach(days.filter { calendar.isDateInWeekend($0) }, id: \.self) { day in
                    RectangleMark(xStart: .value("Day", day), xEnd: .value("Day", day.addingTimeInterval(86400)))
                        .foregroundStyle(StatsStyle.wash)
                }
                if let day = model.day {
                    RectangleMark(xStart: .value("Day", day), xEnd: .value("Day", day.addingTimeInterval(86400)))
                        .foregroundStyle(StatsStyle.accent.opacity(0.13))
                }
                ForEach(Array(stacked.enumerated()), id: \.offset) { _, item in
                    let faded = (picked != nil && item.project.id != picked) || (model.day != nil && model.day != item.day)
                    BarMark(x: .value("Day", item.day, unit: .day), y: .value("Hours", item.seconds / 3600), width: .ratio(0.6))
                        .foregroundStyle(item.project.color.opacity(faded ? 0.25 : 0.9))
                }
                ForEach(days, id: \.self) { day in
                    if let total = model.snapshot.perDay[day], total >= 180 {
                        PointMark(x: .value("Day", day, unit: .day), y: .value("Hours", total / 3600))
                            .opacity(0)
                            .annotation(position: .top, spacing: 2) {
                                Text(StatsStyle.hours(total))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(StatsStyle.muted)
                            }
                    }
                }
                ForEach(days, id: \.self) { day in
                    LineMark(x: .value("Day", day.addingTimeInterval(43200)), y: .value("Target", calendar.isDateInWeekend(day) ? 0 : target),
                             series: .value("Series", "Target"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StatsStyle.target.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                }
            }
            .chartXScale(domain: (days.first ?? model.month)...(model.monthEnd))
            .chartYScale(domain: 0...max(9, maxHours.rounded(.up) + 1))
            .chartXAxis {
                AxisMarks(values: days.map { $0.addingTimeInterval(43200) }) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            VStack(spacing: 0) {
                                Text(date.formatted(.dateTime.weekday(.narrow))).foregroundStyle(StatsStyle.muted)
                                Text(date.formatted(.dateTime.day())).foregroundStyle(StatsStyle.faint)
                            }
                            .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(StatsStyle.border)
                    AxisValueLabel().foregroundStyle(StatsStyle.faint)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame else { return }
                            guard let date: Date = proxy.value(atX: location.x - geo[frame].origin.x) else { return }
                            let day = calendar.startOfDay(for: date)
                            withAnimation(.easeOut(duration: 0.15)) {
                                model.day = model.day == day || (model.snapshot.perDay[day] ?? 0) == 0 ? nil : day
                            }
                        }
                }
            }
        }
        .padding(14)
    }
}

// MARK: - The log: day by day, a session a row

private struct WorkLog: View {
    @ObservedObject var model: StatsModel
    /// Rows opened to show what was asked and committed, by day and session.
    @State private var open: Set<String> = []

    struct Entry: Identifiable {
        let project: StatsProject
        let slice: StatsSessionSlice
        let spans: [WorkSpan]
        let time: TimeInterval
        let prompts: [WorkPrompt]
        let day: Date
        var id: String { "\(day.timeIntervalSince1970)|\(slice.id)" }

        /// How far the commit is from this session's work; nil when it can't be this session's.
        func distance(to commit: WorkCommit) -> TimeInterval? {
            guard commit.repository == project.id, StatsStyle.during(commit, spans) else { return nil }
            return spans.map { commit.date < $0.start ? $0.start.timeIntervalSince(commit.date) : max(0, commit.date.timeIntervalSince($0.end)) }.min()
        }
    }

    struct Day: Identifiable {
        let date: Date
        let entries: [Entry]
        let time: TimeInterval
        /// Each commit goes to the one session it was nearest; the rest are the day's own.
        let byEntry: [String: [WorkCommit]]
        let loose: [WorkCommit]
        var id: Date { date }
        var commitCount: Int { byEntry.values.reduce(0) { $0 + $1.count } + loose.count }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let projectID = model.selectedProjectID
        let sessionID: String? = { if case .session(let id) = model.selection { return id } else { return nil } }()
        let projects = model.snapshot.projects.filter { projectID == nil || $0.id == projectID }
        let folders = Set(projects.map(\.id))
        let shown = model.day.map { [$0] } ?? model.snapshot.days.reversed()
        return shown.compactMap { day in
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            var entries: [Entry] = []
            for project in projects {
                for slice in project.sessions where sessionID == nil || slice.id == sessionID {
                    let spans = WorkStats.clip(slice.spans, from: day, to: next)
                    guard !spans.isEmpty else { continue }
                    entries.append(Entry(project: project, slice: slice, spans: spans, time: spans.reduce(0) { $0 + $1.duration },
                                         prompts: slice.session.prompts.filter { $0.date >= day && $0.date < next }, day: day))
                }
            }
            guard !entries.isEmpty else { return nil }
            entries.sort { ($0.spans.first?.start ?? day) < ($1.spans.first?.start ?? day) }
            var byEntry: [String: [WorkCommit]] = [:]
            var loose: [WorkCommit] = []
            for commit in model.commits where commit.date >= day && commit.date < next && folders.contains(commit.repository) {
                let best = entries.compactMap { entry in entry.distance(to: commit).map { (entry.id, $0) } }.min { $0.1 < $1.1 }
                if let best { byEntry[best.0, default: []].append(commit) } else if sessionID == nil { loose.append(commit) }
            }
            let union = WorkStats.union(entries.flatMap(\.spans))
            return Day(date: day, entries: entries, time: union.reduce(0) { $0 + $1.duration }, byEntry: byEntry, loose: loose)
        }
    }

    var body: some View {
        let days = days
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Daily log").font(.system(size: 15, weight: .bold))
                if let day = model.day {
                    FilterChip(color: StatsStyle.accent, title: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) {
                        model.day = nil
                    }
                }
                switch model.selection {
                case .project(let id):
                    if let project = model.snapshot.project(id) {
                        FilterChip(color: project.color, title: project.name) { model.selection = nil }
                    }
                case .session(let id):
                    if let (project, slice) = model.snapshot.slice(id) {
                        FilterChip(color: project.color, title: slice.session.title) { model.selection = .project(project.id) }
                    }
                case nil: EmptyView()
                }
                Spacer()
                Text("\(days.count) day\(days.count == 1 ? "" : "s") · \(StatsStyle.duration(days.reduce(0) { $0 + $1.time }))")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(StatsStyle.muted)
            }
            if days.isEmpty {
                Text(model.loaded ? "No work logged here." : "Reading conversations…")
                    .font(.system(size: 12))
                    .foregroundStyle(StatsStyle.muted)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                    .statsCard()
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(days) { day in
                    DaySection(model: model, day: day, open: $open)
                }
            }
        }
    }
}

private struct DaySection: View {
    @ObservedObject var model: StatsModel
    let day: WorkLog.Day
    @Binding var open: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.day = model.day == day.date ? nil : day.date }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(day.date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(day.date.formatted(.dateTime.day().month(.wide)))
                            .font(.system(size: 12))
                            .foregroundStyle(StatsStyle.muted)
                        Spacer()
                        Text("\(day.entries.count) session\(day.entries.count == 1 ? "" : "s")" + (day.commitCount == 0 ? "" : " · \(day.commitCount) commit\(day.commitCount == 1 ? "" : "s")"))
                            .font(.system(size: 11))
                            .foregroundStyle(StatsStyle.faint)
                        Text(StatsStyle.duration(day.time))
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    DayTimeline(entries: day.entries, date: day.date)
                }
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.day == day.date ? "Show every day" : "Show only this day, everywhere")
            Rectangle().fill(StatsStyle.border).frame(height: 1)
            ForEach(day.entries) { entry in
                EntryRow(model: model, entry: entry, commits: day.byEntry[entry.id] ?? [],
                         open: open.contains(entry.id)) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if open.contains(entry.id) { open.remove(entry.id) } else { open.insert(entry.id) }
                    }
                }
            }
            if !day.loose.isEmpty {
                let key = "loose|\(day.date.timeIntervalSince1970)"
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { if open.contains(key) { open.remove(key) } else { open.insert(key) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .rotationEffect(.degrees(open.contains(key) ? 90 : 0))
                                .frame(width: 10)
                            Text("\(day.loose.count) commit\(day.loose.count == 1 ? "" : "s") outside a Claude session")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(StatsStyle.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open.contains(key) { CommitList(commits: day.loose).padding(.leading, 20) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .statsCard()
    }
}

/// The day from midnight to midnight, with each session's stretches in its project's color.
private struct DayTimeline: View {
    let entries: [WorkLog.Entry]
    let date: Date

    var body: some View {
        Canvas { context, size in
            let day: TimeInterval = 86400
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: CGSize(width: size.width, height: 6)), cornerRadius: 3),
                         with: .color(StatsStyle.wash))
            for hour in stride(from: 6, to: 24, by: 6) {
                let x = size.width * CGFloat(hour) / 24
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: 6)), with: .color(StatsStyle.border))
                context.draw(Text("\(hour):00").font(.system(size: 8.5)).foregroundColor(StatsStyle.faint),
                             at: CGPoint(x: x, y: 9), anchor: .top)
            }
            for entry in entries {
                for span in entry.spans {
                    let x0 = size.width * CGFloat(span.start.timeIntervalSince(date) / day)
                    let x1 = size.width * CGFloat(span.end.timeIntervalSince(date) / day)
                    context.fill(Path(roundedRect: CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: 6), cornerRadius: 2),
                                 with: .color(entry.project.color))
                }
            }
        }
        .frame(height: 20)
    }
}

private struct EntryRow: View {
    @ObservedObject var model: StatsModel
    let entry: WorkLog.Entry
    let commits: [WorkCommit]
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var picked: Bool {
        if case .session(let id) = model.selection { return id == entry.slice.id }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(StatsStyle.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(range)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(StatsStyle.muted)
                        .frame(width: 92, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle().fill(entry.project.color).frame(width: 7, height: 7)
                        Text(entry.project.name).lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 120, alignment: .leading)
                    Text(entry.slice.session.title)
                        .font(.system(size: 12, weight: picked ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label("\(entry.prompts.count)", systemImage: "text.bubble")
                        .frame(width: 44, alignment: .leading)
                        .opacity(entry.prompts.isEmpty ? 0.3 : 1)
                    Label("\(commits.count)", systemImage: "arrow.triangle.branch")
                        .frame(width: 44, alignment: .leading)
                        .opacity(commits.isEmpty ? 0.3 : 1)
                    Text(StatsStyle.duration(entry.time))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(StatsStyle.ink)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(picked ? entry.project.color.opacity(0.12) : hovering ? StatsStyle.wash : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                model.pointed = inside ? "s:" + entry.slice.id : nil
            }
            .contextMenu {
                Button("Show This Session") { model.selection = .session(entry.slice.id) }
                Button("Show \(entry.project.name)") { model.selection = .project(entry.project.id) }
                Button("Open Conversation") { model.open(entry.slice.session) }
            }
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    if !entry.prompts.isEmpty { PromptList(prompts: entry.prompts, lineLimit: 3) }
                    if !commits.isEmpty { CommitList(commits: commits) }
                    HStack(spacing: 8) {
                        Button("Show in graph") { model.selection = .session(entry.slice.id) }
                        Button("Open conversation") { model.open(entry.slice.session) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                .padding(.leading, 126)
                .padding(.trailing, 14)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            Rectangle().fill(StatsStyle.border.opacity(0.6)).frame(height: 1).padding(.leading, 14)
        }
    }

    private var range: String {
        guard let first = entry.spans.first, let last = entry.spans.last else { return "" }
        return "\(StatsStyle.time(first.start)) – \(StatsStyle.time(last.end))"
    }
}
