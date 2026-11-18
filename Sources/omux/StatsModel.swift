import SwiftUI

/// What the statistics window has picked: a project (by folder) or one session.
enum StatsSelection: Hashable {
    case project(String)
    case session(String)
}

/// A session's share of the month in view.
struct StatsSessionSlice: Identifiable {
    let session: WorkSession
    /// Its stretches of work, cut to the month.
    let spans: [WorkSpan]
    let time: TimeInterval
    var id: String { session.id }
}

/// One project's month: its sessions and time.
struct StatsProject: Identifiable {
    /// Its folder.
    let id: String
    let name: String
    let color: Color
    let sessions: [StatsSessionSlice]
    /// Without double counting sessions that ran side by side.
    let total: TimeInterval
    let perDay: [Date: TimeInterval]
    let spans: [WorkSpan]
}

/// The month in view, added up once whenever the sessions or the month change.
struct StatsSnapshot {
    var projects: [StatsProject] = []
    var perDay: [Date: TimeInterval] = [:]
    var total: TimeInterval = 0
    var days: [Date] = []

    func project(_ id: String) -> StatsProject? { projects.first { $0.id == id } }
    func slice(_ id: String) -> (StatsProject, StatsSessionSlice)? {
        for project in projects { if let slice = project.sessions.first(where: { $0.id == id }) { return (project, slice) } }
        return nil
    }
}

@MainActor
final class StatsModel: ObservableObject {
    static let shared = StatsModel()

    @Published private(set) var sessions: [WorkSession] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published var month: Date = StatsModel.startOfMonth(Date()) { didSet { if month != oldValue { day = nil; rebuild(); loadCommits() } } }
    @Published var selection: StatsSelection?
    /// A day picked on the map, the chart or in the log: everything narrows to what was worked on that day
    /// and the log shows only it.
    @Published var day: Date?
    @Published private(set) var snapshot = StatsSnapshot()
    @Published private(set) var commits: [WorkCommit] = []

    private var lastLoad: Date?
    private var commitTask: Task<Void, Never>?

    static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    var monthEnd: Date { Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month }
    var isCurrentMonth: Bool { month == Self.startOfMonth(Date()) }

    /// The project the selection is in, if any.
    var selectedProjectID: String? {
        switch selection {
        case .project(let id): return id
        case .session(let id): return snapshot.slice(id)?.0.id
        case nil: return nil
        }
    }

    /// Reads the transcripts again, at most every 30 seconds unless forced; only the changed
    /// ones are parsed.
    func reload(force: Bool = false) {
        guard !loading else { return }
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < 30 { return }
        loading = true
        let cache = Persistence.directory.appendingPathComponent("work-stats-v\(WorkStats.cacheVersion).json")
        Task.detached(priority: .userInitiated) {
            let sessions = WorkStats.load(cache: cache)
            await MainActor.run {
                self.sessions = sessions
                self.loading = false
                self.loaded = true
                self.lastLoad = Date()
                self.rebuild()
                self.loadCommits()
            }
        }
    }

    func step(_ months: Int) {
        if let date = Calendar.current.date(byAdding: .month, value: months, to: month) { month = date }
    }

    private func rebuild() {
        let from = month, to = monthEnd
        let calendar = Calendar.current
        var byFolder: [String: [StatsSessionSlice]] = [:]
        for session in sessions {
            guard session.end > from, session.start < to else { continue }
            let spans = WorkStats.clip(session.spans, from: from, to: to)
            guard !spans.isEmpty else { continue }
            let slice = StatsSessionSlice(session: session, spans: spans, time: spans.reduce(0) { $0 + $1.duration })
            byFolder[session.cwd, default: []].append(slice)
        }
        let groups = Store.shared.groups
        // Every project keeps one color across months, and no two share one while there are
        // colors to go round: in the order they were first worked in.
        var firstSeen: [String: Date] = [:]
        for session in sessions { firstSeen[session.cwd] = min(firstSeen[session.cwd] ?? .distantFuture, session.start) }
        var colors: [String: Color] = [:]
        for (i, folder) in firstSeen.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }).map(\.key).enumerated() {
            colors[folder] = StatsStyle.palette[i % StatsStyle.palette.count]
        }
        let projects = byFolder.map { folder, slices -> StatsProject in
            let spans = WorkStats.union(slices.flatMap(\.spans))
            let name = groups.first { Store.samePath($0.directory, folder) }?.name
                ?? (folder == NSHomeDirectory() ? "Home" : (folder as NSString).lastPathComponent)
            return StatsProject(id: folder, name: name, color: colors[folder] ?? StatsStyle.color(for: folder),
                                sessions: slices.sorted { $0.session.end > $1.session.end },
                                total: spans.reduce(0) { $0 + $1.duration },
                                perDay: WorkStats.perDay(spans), spans: spans)
        }.sorted { $0.total > $1.total }
        let all = WorkStats.union(projects.flatMap(\.spans))
        var days: [Date] = []
        var day = from
        while day < to {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        snapshot = StatsSnapshot(projects: projects, perDay: WorkStats.perDay(all),
                                 total: all.reduce(0) { $0 + $1.duration }, days: days)
        if let selection {
            switch selection {
            case .project(let id) where snapshot.project(id) == nil: self.selection = nil
            case .session(let id) where snapshot.slice(id) == nil: self.selection = nil
            default: break
            }
        }
    }

    /// The month's commits in every project's repository, read off the main thread.
    private func loadCommits() {
        commitTask?.cancel()
        let folders = snapshot.projects.map(\.id).filter { $0 != NSHomeDirectory() }
        let from = month, to = monthEnd
        commitTask = Task.detached(priority: .utility) {
            var found: [WorkCommit] = []
            var seen = Set<String>()
            for folder in folders {
                if Task.isCancelled { return }
                for commit in WorkStats.commits(in: folder, from: from, to: to) where seen.insert(commit.id).inserted {
                    found.append(commit)
                }
            }
            let result = found.sorted { $0.date > $1.date }
            await MainActor.run { if !Task.isCancelled { self.commits = result } }
        }
    }

    /// Each project's share of each day, scaled so a day's shares add up to its total: sessions
    /// in two projects at once count once, as the day's total does.
    func stacked() -> [(day: Date, project: StatsProject, seconds: TimeInterval)] {
        var result: [(Date, StatsProject, TimeInterval)] = []
        for day in snapshot.days {
            let total = snapshot.perDay[day] ?? 0
            guard total > 0 else { continue }
            let raw = snapshot.projects.map { ($0, $0.perDay[day] ?? 0) }.filter { $0.1 > 0 }
            let sum = raw.reduce(0) { $0 + $1.1 }
            for (project, seconds) in raw { result.append((day, project, seconds * total / max(sum, 1))) }
        }
        return result
    }

    func commits(in project: String) -> [WorkCommit] {
        commits.filter { $0.repository == project }
    }

    /// Opens the session's conversation in the main window.
    func open(_ session: WorkSession) {
        guard let id = UUID(uuidString: session.id) else { return }
        Store.shared.openClaudeSession(RecentSession(id: id, cwd: session.cwd, prompt: session.title, date: session.end))
        Store.shared.showStats = false
    }
}

/// The statistics page's look.
enum StatsStyle {
    // Drawn on omux's own theme: everything leans on the theme's text color.
    static let card = Color.primary.opacity(0.035)
    static let border = Color.primary.opacity(0.09)
    static let wash = Color.primary.opacity(0.055)
    static let ink = Color.primary
    static let muted = Color.primary.opacity(0.62)
    static let faint = Color.primary.opacity(0.4)
    static let accent = Color.accentColor
    static let bar = Color(red: 0.42, green: 0.77, blue: 0.48)
    static let target = Color(red: 0.95, green: 0.62, blue: 0.30)

    static let palette: [Color] = [
        Color(red: 0.27, green: 0.38, blue: 0.84), Color(red: 0.42, green: 0.70, blue: 0.40),
        Color(red: 0.91, green: 0.55, blue: 0.22), Color(red: 0.62, green: 0.40, blue: 0.82),
        Color(red: 0.87, green: 0.33, blue: 0.43), Color(red: 0.16, green: 0.62, blue: 0.68),
        Color(red: 0.80, green: 0.66, blue: 0.16), Color(red: 0.45, green: 0.52, blue: 0.60),
        Color(red: 0.86, green: 0.42, blue: 0.70), Color(red: 0.33, green: 0.58, blue: 0.86),
    ]

    /// The same project gets the same color every month.
    static func color(for folder: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in folder.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// "5h 12m", "48m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "8.27": hours as a time sheet writes them.
    static func hours(_ seconds: TimeInterval) -> String {
        let value = (seconds / 3600 * 100).rounded() / 100
        return value == value.rounded() ? String(Int(value)) : String(format: value * 10 == (value * 10).rounded() ? "%.1f" : "%.2f", value)
    }

    /// A commit belongs to a stretch of work made from a few minutes before it to a quarter
    /// hour after: committing is often the last thing, after the agent went quiet.
    static func during(_ commit: WorkCommit, _ spans: [WorkSpan]) -> Bool {
        spans.contains { commit.date >= $0.start.addingTimeInterval(-300) && commit.date <= $0.end.addingTimeInterval(900) }
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
