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
    /// Its tokens in the month.
    let tokens: WorkTokens
    var id: String { session.id }

    /// Its tokens on one day.
    func tokens(on day: Date) -> WorkTokens { session.tokenDays.first { $0.day == day }?.tokens ?? WorkTokens() }
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
    let tokens: WorkTokens
    let tokensPerDay: [Date: Int]
}

/// One day's work, for the year calendar.
struct StatsDayTotal: Equatable {
    var time: TimeInterval = 0
    var tokens = 0
}

/// The stretch of time the page shows.
enum StatsRange: Hashable {
    case last24Hours, last7Days, last30Days
    case month(Date)

    enum Kind: String, CaseIterable { case hours = "24h", week = "7 days", days30 = "30 days", month = "Month" }
    var kind: Kind {
        switch self {
        case .last24Hours: return .hours
        case .last7Days: return .week
        case .last30Days: return .days30
        case .month: return .month
        }
    }
    static func of(_ kind: Kind) -> StatsRange {
        switch kind {
        case .hours: return .last24Hours
        case .week: return .last7Days
        case .days30: return .last30Days
        case .month: return .month(StatsModel.startOfMonth(Date()))
        }
    }

    /// [from, to) as of `now`: whole hours for the last day, whole days otherwise.
    func interval(now: Date = Date()) -> (from: Date, to: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch self {
        case .last24Hours:
            let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            return (hour.addingTimeInterval(-23 * 3600), hour.addingTimeInterval(3600))
        case .last7Days: return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, tomorrow)
        case .last30Days: return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, tomorrow)
        case .month(let month): return (month, calendar.date(byAdding: .month, value: 1, to: month) ?? month)
        }
    }

    /// "in the last 7 days", "in November 2026".
    var phrase: String {
        switch self {
        case .last24Hours: return "in the last 24 hours"
        case .last7Days: return "in the last 7 days"
        case .last30Days: return "in the last 30 days"
        case .month(let month): return "in " + month.formatted(.dateTime.month(.wide).year())
        }
    }

    /// "Last 7 days", "November 2026".
    var title: String {
        switch self {
        case .last24Hours: return "Last 24 hours"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .month(let month): return month.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The dates it covers: "14 – 20 Nov 2026", "20 Nov 2026, 09:00 – 21 Nov, 09:00".
    func dates(now: Date = Date()) -> String {
        let (from, to) = interval(now: now)
        if self == .last24Hours {
            return "\(from.formatted(.dateTime.day().month(.abbreviated).hour().minute())) – \(to.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
        }
        let last = to.addingTimeInterval(-1)
        return "\(from.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }
}

/// One project's share of one day (or hour) in the hours chart.
struct StatsBar: Equatable {
    let day: Date
    let project: String
    let color: Color
    let seconds: TimeInterval
}

/// The month in view, added up once whenever the sessions or the month change.
struct StatsSnapshot {
    var projects: [StatsProject] = []
    var perDay: [Date: TimeInterval] = [:]
    var total: TimeInterval = 0
    var tokens = WorkTokens()
    var days: [Date] = []
    /// The chart's columns: the days, or for the last 24 hours its hours.
    var buckets: [Date] = []
    var perBucket: [Date: TimeInterval] = [:]
    var hourly = false

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
    @Published var range: StatsRange = .month(StatsModel.startOfMonth(Date())) { didSet { if range != oldValue { day = nil; rebuild(); loadCommits() } } }
    /// The range's bounds as of the last rebuild.
    private(set) var from = Date()
    private(set) var to = Date()
    @Published var selection: StatsSelection? { didSet { if selection != oldValue { updateYear() } } }
    /// The last 53 weeks day by day, for the picked project or for all: the year calendar.
    @Published private(set) var year: [Date: StatsDayTotal] = [:]
    private var yearAll: [Date: StatsDayTotal] = [:]
    private var yearByProject: [String: [Date: StatsDayTotal]] = [:]
    /// Each project's share of each day of the month, for the hours chart.
    @Published private(set) var bars: [StatsBar] = []
    /// A day picked on the map, the chart or in the log: everything narrows to what was worked on that day
    /// and the log shows only it.
    @Published var day: Date?
    @Published private(set) var snapshot = StatsSnapshot()
    @Published private(set) var commits: [WorkCommit] = []

    private var lastLoad: Date?
    private var commitTask: Task<Void, Never>?

    nonisolated static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    /// The month in view, when the range is one.
    var month: Date? { if case .month(let month) = range { return month } else { return nil } }
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
                self.computeYear()
                self.loadCommits()
            }
        }
    }

    func step(_ months: Int) {
        if let month, let date = Calendar.current.date(byAdding: .month, value: months, to: month) { range = .month(date) }
    }

    /// Whether the day is in the range in view.
    func covers(_ day: Date) -> Bool { day >= Calendar.current.startOfDay(for: from) && day < to }

    private func rebuild() {
        (from, to) = range.interval()
        let from = from, to = to
        let calendar = Calendar.current
        var byFolder: [String: [StatsSessionSlice]] = [:]
        for session in sessions {
            guard session.end > from, session.start < to else { continue }
            let spans = WorkStats.clip(session.spans, from: from, to: to)
            guard !spans.isEmpty else { continue }
            let slice = StatsSessionSlice(session: session, spans: spans, time: spans.reduce(0) { $0 + $1.duration },
                                          tokens: session.tokens(from: from, to: to))
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
            var tokensPerDay: [Date: Int] = [:]
            for slice in slices {
                for hour in slice.session.tokenHours where hour.day >= from && hour.day < to {
                    tokensPerDay[calendar.startOfDay(for: hour.day), default: 0] += hour.tokens.total
                }
            }
            return StatsProject(id: folder, name: name, color: colors[folder] ?? StatsStyle.color(for: folder),
                                sessions: slices.sorted { $0.session.end > $1.session.end },
                                total: spans.reduce(0) { $0 + $1.duration },
                                perDay: WorkStats.perDay(spans), spans: spans,
                                tokens: slices.reduce(WorkTokens()) { $0 + $1.tokens }, tokensPerDay: tokensPerDay)
        }.sorted { $0.total > $1.total }
        let all = WorkStats.union(projects.flatMap(\.spans))
        func steps(_ unit: Calendar.Component, from start: Date) -> [Date] {
            var result: [Date] = []
            var cursor = start
            while cursor < to {
                result.append(cursor)
                guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
                cursor = next
            }
            return result
        }
        let hourly = range == .last24Hours
        let days = steps(.day, from: calendar.startOfDay(for: from))
        let unit: Calendar.Component = hourly ? .hour : .day
        snapshot = StatsSnapshot(projects: projects, perDay: WorkStats.perDay(all),
                                 total: all.reduce(0) { $0 + $1.duration },
                                 tokens: projects.reduce(WorkTokens()) { $0 + $1.tokens }, days: days,
                                 buckets: hourly ? steps(.hour, from: from) : days,
                                 perBucket: WorkStats.per(unit, all), hourly: hourly)
        bars = stacked(unit)
        if let selection {
            switch selection {
            case .project(let id) where snapshot.project(id) == nil: self.selection = nil
            case .session(let id) where snapshot.slice(id) == nil: self.selection = nil
            default: break
            }
        }
    }

    /// The first day the year calendar shows: the start of the week a year ago.
    static var yearStart: Date {
        let calendar = Calendar.current
        let week = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .weekOfYear, value: -52, to: week) ?? week
    }

    /// Every day of the last year, for all projects and for each.
    private func computeYear() {
        let from = Self.yearStart
        var spans: [String: [WorkSpan]] = [:]
        var tokens: [String: [Date: Int]] = [:]
        for session in sessions where session.end > from {
            spans[session.cwd, default: []] += WorkStats.clip(session.spans, from: from, to: .distantFuture)
            for day in session.tokenDays where day.day >= from { tokens[session.cwd, default: [:]][day.day, default: 0] += day.tokens.total }
        }
        func totals(_ spans: [WorkSpan], _ tokens: [Date: Int]) -> [Date: StatsDayTotal] {
            var result: [Date: StatsDayTotal] = [:]
            for (day, time) in WorkStats.perDay(WorkStats.union(spans)) { result[day, default: StatsDayTotal()].time = time }
            for (day, count) in tokens { result[day, default: StatsDayTotal()].tokens += count }
            return result
        }
        var byProject: [String: [Date: StatsDayTotal]] = [:]
        for folder in Set(spans.keys).union(tokens.keys) { byProject[folder] = totals(spans[folder] ?? [], tokens[folder] ?? [:]) }
        yearByProject = byProject
        yearAll = totals(spans.values.flatMap { $0 }, tokens.values.reduce(into: [:]) { all, days in all.merge(days, uniquingKeysWith: +) })
        updateYear()
    }

    private func updateYear() {
        let next = selectedProjectID.map { yearByProject[$0] ?? [:] } ?? yearAll
        if next != year { year = next }
    }

    /// The month's commits in every project's repository, read off the main thread.
    private func loadCommits() {
        commitTask?.cancel()
        let folders = snapshot.projects.map(\.id).filter { $0 != NSHomeDirectory() }
        let from = from, to = to
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

    /// Each project's share of each day (or hour), scaled so a column's shares add up to its
    /// total: sessions in two projects at once count once, as the total does.
    private func stacked(_ unit: Calendar.Component) -> [StatsBar] {
        let each = snapshot.projects.map { ($0, unit == .day ? $0.perDay : WorkStats.per(unit, $0.spans)) }
        var result: [StatsBar] = []
        for bucket in snapshot.buckets {
            let total = snapshot.perBucket[bucket] ?? 0
            guard total > 0 else { continue }
            let raw = each.map { ($0.0, $0.1[bucket] ?? 0) }.filter { $0.1 > 0 }
            let sum = raw.reduce(0) { $0 + $1.1 }
            for (project, seconds) in raw {
                result.append(StatsBar(day: bucket, project: project.id, color: project.color, seconds: seconds * total / max(sum, 1)))
            }
        }
        return result
    }

    /// The year calendar's days for every project but `excluded`.
    func yearTotals(excluding excluded: Set<String>) -> [Date: StatsDayTotal] {
        guard !excluded.isEmpty else { return yearAll }
        var result: [Date: StatsDayTotal] = [:]
        for (folder, days) in yearByProject where !excluded.contains(folder) {
            for (day, total) in days {
                result[day, default: StatsDayTotal()].time += total.time
                result[day, default: StatsDayTotal()].tokens += total.tokens
            }
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

    /// "1.24B", "312M", "48.2K".
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        func short(_ v: Double, _ unit: String) -> String { (v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)) + unit }
        if value >= 1e9 { return short(value / 1e9, "B") }
        if value >= 1e6 { return short(value / 1e6, "M") }
        if value >= 1e3 { return short(value / 1e3, "K") }
        return "\(count)"
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
