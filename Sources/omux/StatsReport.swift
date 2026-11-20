import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A report of the statistics to send to someone: one page, set up in one place (what range,
// which parts, which projects, what stays private, light or dark), and saved as a picture, a
// PDF or Markdown, copied, or handed to the system's share menu.

/// How the report is set up; kept between reports.
struct ReportOptions: Codable, Hashable {
    var title = "Claude Code work report"
    var author = ""
    var summary = true
    var calendar = true
    var calendarTokens = false
    var bubbles = true
    var hours = true
    var projects = true
    var sessions = true
    var commits = true
    var hideProjects = false
    var hideSessions = false
    var hideCommits = false
    /// A small card to post, or the whole report.
    var card = true
    var dark = true
    var wide = true
    /// Projects left out, by folder.
    var excluded: [String] = []

    var width: CGFloat { card ? ShareCard.size.width : wide ? 1040 : 760 }

    static let key = "statsReportOptions"
    static func load() -> ReportOptions {
        guard let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
              let options = try? JSONDecoder().decode(ReportOptions.self, from: data) else { return ReportOptions() }
        return options
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.key) }
    }
}

/// What the report shows, worked out from the page's numbers and the options.
struct ReportData {
    struct Project: Identifiable {
        let id: String
        let name: String
        let color: Color
        let time: TimeInterval
        let tokens: Int
        let sessions: Int
        let commits: Int
    }
    struct Session: Identifiable {
        let id: String
        let title: String
        let project: String
        let color: Color
        let start: Date
        let time: TimeInterval
        let tokens: Int
    }
    struct Commit: Identifiable {
        let id: String
        let subject: String
        let project: String
        let color: Color
        let date: Date
    }

    var range = ""
    var dates = ""
    var generated = Date()
    var projects: [Project] = []
    var time: TimeInterval = 0
    var tokens = WorkTokens()
    var activeDays = 0
    var sessionCount = 0
    var requests = 0
    var commitCount = 0
    var bars: [StatsBar] = []
    var buckets: [Date] = []
    var perBucket: [Date: TimeInterval] = [:]
    var hourly = false
    var year: [Date: StatsDayTotal] = [:]
    var packing = TokenBubbles.Packing()
    var sessions: [Session] = []
    var commits: [Commit] = []

    @MainActor
    init(model: StatsModel, options: ReportOptions) {
        let excluded = Set(options.excluded)
        let snapshot = model.snapshot
        let included = snapshot.projects.filter { !excluded.contains($0.id) }
        var names: [String: String] = [:]
        for (i, project) in included.enumerated() {
            names[project.id] = options.hideProjects ? "Project " + (i < 26 ? String(UnicodeScalar(65 + i).map(Character.init) ?? "?") : "\(i + 1)") : project.name
        }
        func title(_ slice: StatsSessionSlice) -> String {
            options.hideSessions ? "Session on " + slice.session.start.formatted(.dateTime.day().month(.abbreviated).hour().minute()) : slice.session.title
        }
        let folders = Set(included.map(\.id))
        let commits = model.commits.filter { folders.contains($0.repository) }
        range = model.range.title
        dates = model.range.dates()
        projects = included.map { project in
            Project(id: project.id, name: names[project.id] ?? project.name, color: project.color, time: project.total,
                    tokens: project.tokens.total, sessions: project.sessions.count,
                    commits: commits.filter { $0.repository == project.id }.count)
        }
        let all = WorkStats.union(included.flatMap(\.spans))
        time = all.reduce(0) { $0 + $1.duration }
        tokens = included.reduce(WorkTokens()) { $0 + $1.tokens }
        activeDays = WorkStats.perDay(all).values.filter { $0 >= 60 }.count
        sessionCount = included.reduce(0) { $0 + $1.sessions.count }
        requests = included.reduce(0) { $0 + $1.sessions.reduce(0) { $0 + $1.session.prompts.count } }
        commitCount = commits.count
        bars = model.bars.filter { folders.contains($0.project) }
        for bar in bars { perBucket[bar.day, default: 0] += bar.seconds }
        buckets = snapshot.buckets
        hourly = snapshot.hourly
        year = model.yearTotals(excluding: excluded)
        packing = TokenBubbles.packing(included, name: { names[$0.id] ?? $0.name }, title: title)
        sessions = included.flatMap { project in
            project.sessions.map { slice in
                Session(id: slice.id, title: title(slice), project: names[project.id] ?? project.name, color: project.color,
                        start: slice.spans.first?.start ?? slice.session.start, time: slice.time, tokens: slice.tokens.total)
            }
        }.sorted { $0.time > $1.time }
        self.commits = commits.prefix(20).map { commit in
            let project = included.first { $0.id == commit.repository }
            return Commit(id: commit.id, subject: options.hideCommits ? "Commit" : commit.subject,
                          project: names[commit.repository] ?? "", color: project?.color ?? StatsStyle.faint, date: commit.date)
        }
    }

    /// The report as Markdown, for a message or a document.
    func markdown(_ options: ReportOptions) -> String {
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["# \(options.title)", "", "**\(range)** · \(dates)" + (options.author.isEmpty ? "" : " · \(options.author)"), ""]
        if options.summary {
            lines += ["| Active time | Active days | Projects | Sessions | Tokens | Commits |", "|---|---|---|---|---|---|",
                      "| \(StatsStyle.duration(time)) | \(activeDays) | \(projects.count) | \(sessionCount) | \(StatsStyle.tokens(tokens.total)) | \(commitCount) |", ""]
        }
        if options.projects, !projects.isEmpty {
            lines += ["## Projects", "", "| Project | Time | Tokens | Sessions | Commits |", "|---|---:|---:|---:|---:|"]
            lines += projects.map { "| \(cell($0.name)) | \(StatsStyle.duration($0.time)) | \(StatsStyle.tokens($0.tokens)) | \($0.sessions) | \($0.commits) |" }
            lines.append("")
        }
        if options.sessions, !sessions.isEmpty {
            lines += ["## Longest sessions", "", "| Session | Project | Time | Tokens |", "|---|---|---:|---:|"]
            lines += sessions.prefix(10).map { "| \(cell($0.title)) | \(cell($0.project)) | \(StatsStyle.duration($0.time)) | \(StatsStyle.tokens($0.tokens)) |" }
            lines.append("")
        }
        if options.commits, !commits.isEmpty {
            lines += ["## Commits", ""]
            lines += commits.map { "- `\($0.id.prefix(7))` \(cell($0.subject))" + ($0.project.isEmpty ? "" : " — \(cell($0.project))") }
            lines.append("")
        }
        lines.append("_Made with omux, from Claude Code conversations · \(generated.formatted(date: .abbreviated, time: .shortened))_")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The page

struct ReportView: View {
    let data: ReportData
    let options: ReportOptions

    private var scheme: ColorScheme { options.dark ? .dark : .light }
    private var inner: CGFloat { options.width - 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if options.summary { summary }
            if options.calendar { calendar }
            if options.bubbles, !data.packing.bubbles.isEmpty { bubbles }
            if options.hours, !data.buckets.isEmpty {
                DailyChart(model: nil, bars: data.bars, buckets: data.buckets, perBucket: data.perBucket, total: data.time,
                           picked: nil, day: nil, hourly: data.hourly)
                    .frame(height: 230)
                    .statsCard()
            }
            if options.projects, !data.projects.isEmpty { projects }
            if options.sessions, !data.sessions.isEmpty { sessions }
            if options.commits, !data.commits.isEmpty { commits }
            footer
        }
        .padding(32)
        .frame(width: options.width, alignment: .topLeading)
        .background(options.dark ? Color(red: 0.035, green: 0.04, blue: 0.05) : Color(red: 0.985, green: 0.985, blue: 0.98))
        .environment(\.colorScheme, scheme)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(options.title.isEmpty ? "Work report" : options.title).font(.system(size: 26, weight: .bold))
                Text("\(data.range) · \(data.dates)" + (options.author.isEmpty ? "" : "  ·  \(options.author)"))
                    .font(.system(size: 13))
                    .foregroundStyle(StatsStyle.muted)
            }
            Spacer()
            Label("omux", systemImage: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StatsStyle.faint)
        }
        .padding(.bottom, 4)
    }

    private var summary: some View {
        let items: [(String, String, String)] = [
            ("Active time", StatsStyle.duration(data.time), "\(StatsStyle.hours(data.time)) hours"),
            ("Active days", "\(data.activeDays)", data.activeDays > 0 ? "\(StatsStyle.duration(data.time / Double(data.activeDays))) a day" : "—"),
            ("Projects", "\(data.projects.count)", data.projects.first.map { "most on \($0.name)" } ?? "—"),
            ("Sessions", "\(data.sessionCount)", "\(data.requests) requests"),
            ("Tokens", StatsStyle.tokens(data.tokens.total), "\(StatsStyle.tokens(data.tokens.output)) written"),
            ("Commits", "\(data.commitCount)", "in their repositories"),
        ]
        let perRow = options.wide ? 6 : 3
        return VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 10) {
                    ForEach(items[start..<min(start + perRow, items.count)], id: \.0) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.0.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(StatsStyle.faint)
                            Text(item.1).font(.system(size: 20, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                            Text(item.2).font(.system(size: 11)).foregroundStyle(StatsStyle.muted).lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .statsCard()
                    }
                }
            }
        }
    }

    private var calendar: some View {
        let days = ContributionCalendar.days()
        let values = days.map { day -> Double in
            guard let total = data.year[day] else { return 0 }
            return options.calendarTokens ? Double(total.tokens) : total.time
        }
        let thresholds = ContributionCalendar.quartiles(values)
        let step = min(18, ((inner - 32 - ContributionCalendar.labelWidth) / CGFloat(ContributionCalendar.weeks)).rounded(.down))
        let size = ContributionCalendar.size(step: step)
        let total = values.reduce(0, +)
        let scheme = scheme
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(options.calendarTokens ? "\(StatsStyle.tokens(Int(total))) tokens in the last year" : "\(StatsStyle.hours(total)) hours in the last year")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 3) {
                    Text("Less").padding(.trailing, 3)
                    RoundedRectangle(cornerRadius: 2).fill(ContributionCalendar.empty(scheme)).frame(width: 10, height: 10)
                    ForEach(0..<4, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(ContributionCalendar.greens(scheme)[$0]).frame(width: 10, height: 10) }
                    Text("More").padding(.leading, 3)
                }
                .font(.system(size: 11))
                .foregroundStyle(StatsStyle.faint)
            }
            Canvas { context, _ in
                ContributionCalendar.draw(in: &context, days: days, values: values, thresholds: thresholds, step: step, scheme: scheme)
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .statsCard()
    }

    private var bubbles: some View {
        let packing = data.packing
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Where the tokens went").font(.system(size: 13, weight: .semibold))
                Text("\(StatsStyle.tokens(data.tokens.total)) in all").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(StatsStyle.muted)
                Spacer()
                Text("bigger bubble, more tokens").font(.system(size: 11)).foregroundStyle(StatsStyle.faint)
            }
            Canvas { context, size in
                TokenBubbles.draw(packing, in: &context, fit: TokenBubbles.fitting(packing.bounds, in: size), time: nil)
            }
            .frame(height: options.wide ? 400 : 340)
        }
        .padding(16)
        .statsCard()
    }

    private var projects: some View {
        let top = data.projects.map(\.time).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            Text("Projects").font(.system(size: 13, weight: .semibold)).padding(.bottom, 10)
            row(Text("PROJECT"), Text(""), Text("TIME"), Text("TOKENS"), Text("SESSIONS"), Text("COMMITS"))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(StatsStyle.faint)
                .padding(.bottom, 6)
            ForEach(data.projects) { project in
                Rectangle().fill(StatsStyle.border).frame(height: 1)
                row(Text(project.name).fontWeight(.medium),
                    Capsule().fill(project.color.opacity(0.85)).frame(width: max(3, 150 * project.time / max(top, 1)), height: 5),
                    Text(StatsStyle.duration(project.time)), Text(StatsStyle.tokens(project.tokens)),
                    Text("\(project.sessions)"), Text("\(project.commits)"), color: project.color)
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.vertical, 7)
            }
        }
        .padding(16)
        .statsCard()
    }

    private func row(_ name: some View, _ bar: some View, _ time: some View, _ tokens: some View, _ sessions: some View,
                     _ commits: some View, color: Color? = nil) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                name.lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            bar.frame(width: 150, alignment: .leading)
            time.frame(width: 70, alignment: .trailing)
            tokens.frame(width: 70, alignment: .trailing)
            sessions.frame(width: 64, alignment: .trailing)
            commits.frame(width: 64, alignment: .trailing)
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Longest sessions").font(.system(size: 13, weight: .semibold)).padding(.bottom, 8)
            ForEach(Array(data.sessions.prefix(10).enumerated()), id: \.offset) { i, session in
                if i > 0 { Rectangle().fill(StatsStyle.border).frame(height: 1) }
                HStack(spacing: 10) {
                    Text(session.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle().fill(session.color).frame(width: 7, height: 7)
                        Text(session.project).lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 140, alignment: .leading)
                    Text(session.start.formatted(.dateTime.day().month(.abbreviated)))
                        .foregroundStyle(StatsStyle.muted)
                        .frame(width: 60, alignment: .leading)
                    Text(StatsStyle.tokens(session.tokens)).foregroundStyle(StatsStyle.muted).frame(width: 60, alignment: .trailing)
                    Text(StatsStyle.duration(session.time)).fontWeight(.medium).frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 11.5).monospacedDigit())
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .statsCard()
    }

    private var commits: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(data.commitCount > data.commits.count ? "Latest commits · \(data.commits.count) of \(data.commitCount)" : "Commits")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 4)
            ForEach(data.commits) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(commit.id.prefix(7))).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(StatsStyle.accent)
                    Text(commit.subject).font(.system(size: 11.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle().fill(commit.color).frame(width: 6, height: 6)
                        Text(commit.project).lineLimit(1)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(StatsStyle.muted)
                    Text(commit.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(StatsStyle.faint)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .statsCard()
    }

    private var footer: some View {
        Text("Made with omux, from Claude Code conversations · \(data.generated.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 10.5))
            .foregroundStyle(StatsStyle.faint)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}

// MARK: - The card

/// The period on one small picture: the hours, the tokens, what they went to, and the days
/// they were worked; made to be posted.
struct ShareCard: View {
    let data: ReportData
    let options: ReportOptions

    static let size = CGSize(width: 640, height: 360)

    private var dark: Bool { options.dark }
    private var ink: Color { dark ? .white : Color(red: 0.07, green: 0.08, blue: 0.1) }
    private var muted: Color { ink.opacity(0.58) }
    private var faint: Color { ink.opacity(0.36) }
    private var green: Color { ContributionCalendar.greens(dark ? .dark : .light)[dark ? 3 : 1] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(data.range.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(green)
                Text(data.dates).font(.system(size: 11).monospacedDigit()).foregroundStyle(faint)
                Spacer()
                if !options.author.isEmpty { Text(options.author).font(.system(size: 12, weight: .semibold)).foregroundStyle(muted) }
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(StatsStyle.duration(data.time)).font(.system(size: 56, weight: .heavy).monospacedDigit()).foregroundStyle(ink)
                Text("with Claude Code").font(.system(size: 17, weight: .medium)).foregroundStyle(muted)
            }
            .padding(.top, 14)
            HStack(spacing: 22) {
                stat(StatsStyle.tokens(data.tokens.total), "tokens")
                stat("\(data.sessionCount)", "sessions")
                stat("\(data.projects.count)", "projects")
                stat("\(data.commitCount)", "commits")
                if !data.hourly { stat("\(data.activeDays)", data.activeDays == 1 ? "day" : "days") }
            }
            .padding(.top, 8)
            Spacer(minLength: 16)
            HStack(alignment: .bottom, spacing: 28) {
                bars.frame(maxWidth: .infinity)
                projects.frame(width: 230)
            }
            .frame(height: 96)
            HStack {
                Label("omux", systemImage: "chart.bar.xaxis").font(.system(size: 11, weight: .bold)).foregroundStyle(muted)
                Spacer()
                Text(data.hourly ? "active minutes, hour by hour" : "hours worked, day by day")
                    .font(.system(size: 10)).foregroundStyle(faint)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(background)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.05, green: 0.07, blue: 0.09), Color(red: 0.09, green: 0.11, blue: 0.14)]
                                        : [Color(red: 1, green: 1, blue: 1), Color(red: 0.94, green: 0.95, blue: 0.96)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [green.opacity(dark ? 0.16 : 0.12), .clear], center: .topTrailing, startRadius: 10, endRadius: 360)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(ink)
            Text(label).font(.system(size: 12)).foregroundStyle(muted)
        }
    }

    /// A bar a day (an hour for the last day), as tall as its time.
    private var bars: some View {
        let values = data.buckets.map { data.perBucket[$0] ?? 0 }
        let top = max(values.max() ?? 0, 1)
        let green = green, empty = ink.opacity(dark ? 0.08 : 0.07)
        return Canvas { context, size in
            let count = max(values.count, 1)
            let step = size.width / CGFloat(count)
            let width = max(2, step * (count > 14 ? 0.68 : 0.56))
            for (i, value) in values.enumerated() {
                let height = value > 0 ? max(4, size.height * CGFloat(value / top)) : 3
                let rect = CGRect(x: CGFloat(i) * step + (step - width) / 2, y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                             with: .color(value > 0 ? green.opacity(0.35 + 0.65 * value / top) : empty))
            }
        }
    }

    /// The three projects with the most time, and how much of it each took.
    private var projects: some View {
        let top = Array(data.projects.prefix(3))
        let total = max(data.projects.reduce(0) { $0 + $1.time }, 1)
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(top) { project in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(project.color).frame(width: 7, height: 7)
                        Text(project.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int((project.time / total * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
                    }
                    GeometryReader { geo in
                        Capsule().fill(ink.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(project.color).frame(width: max(4, geo.size.width * project.time / total))
                            }
                    }
                    .frame(height: 4)
                }
            }
            if data.projects.count > 3 {
                Text("+ \(data.projects.count - 3) more").font(.system(size: 10.5)).foregroundStyle(faint)
            }
        }
    }
}

// MARK: - Making files

@MainActor
enum ReportExport {
    private static func renderer(_ data: ReportData, _ options: ReportOptions) -> ImageRenderer<AnyView> {
        let page = options.card ? AnyView(ShareCard(data: data, options: options)) : AnyView(ReportView(data: data, options: options))
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(width: options.width, height: options.card ? ShareCard.size.height : nil)
        renderer.scale = 2
        return renderer
    }

    static func image(_ data: ReportData, _ options: ReportOptions) -> NSImage? { renderer(data, options).nsImage }

    static func png(_ data: ReportData, _ options: ReportOptions) -> Data? {
        guard let image = renderer(data, options).cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// One tall PDF page, its text kept as text.
    static func pdf(_ data: ReportData, _ options: ReportOptions) -> Data? {
        let output = NSMutableData()
        var made = false
        renderer(data, options).render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: output as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            made = true
        }
        return made ? output as Data : nil
    }

    /// A file name from the title and range.
    static func fileName(_ options: ReportOptions, _ data: ReportData, _ ext: String) -> String {
        let base = "\(options.title.isEmpty ? "Work report" : options.title) – \(data.range)"
        return base.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression) + "." + ext
    }
}

/// Holds the share button's view, for the share menu to open from.
final class ShareAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ShareAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

// MARK: - The sheet

/// Everything about the report in one place: settings on the left, the page as it will be on
/// the right, and the ways out at the bottom.
struct ShareReportSheet: View {
    @ObservedObject var model: StatsModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ReportOptions.load()
    @State private var preview: NSImage?
    @State private var status: String?
    @State private var anchor = ShareAnchor()

    private struct RenderKey: Hashable {
        let options: ReportOptions
        let range: StatsRange
        let tokens: Int
        let time: TimeInterval
        let commits: Int
    }

    private var renderKey: RenderKey {
        RenderKey(options: options, range: model.range, tokens: model.snapshot.tokens.total, time: model.snapshot.total, commits: model.commits.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView { settings.padding(18) }
                    .frame(width: 310)
                Divider()
                previewPane
            }
            Divider()
            actions
        }
        .frame(width: 1120, height: 760)
        .onChange(of: options) { _, options in options.save() }
        .task(id: renderKey) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            preview = ReportExport.image(ReportData(model: model, options: options), options)
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Range") {
                RangePicker(range: $model.range)
                HStack(spacing: 6) {
                    if model.month != nil {
                        Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                        Text(model.range.title).font(.system(size: 12, weight: .medium)).frame(minWidth: 110)
                        Button { model.step(1) } label: { Image(systemName: "chevron.right") }.disabled(model.isCurrentMonth)
                    } else {
                        Text(model.range.dates()).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
            }
            group("Format") {
                Picker("", selection: $options.card) {
                    Text("Card").tag(true)
                    Text("Full report").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(options.card ? "One picture, 1280 × 720, to post on X, LinkedIn or Slack." : "Every part, one long page, for a time sheet or a client.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            group(options.card ? "Name" : "Title") {
                if !options.card { TextField("Title", text: $options.title).textFieldStyle(.roundedBorder) }
                TextField(options.card ? "Name or @handle (optional)" : "Your name (optional)", text: $options.author).textFieldStyle(.roundedBorder)
            }
            if !options.card { sections }
            projectList
            group("Privacy") {
                Toggle("Hide project names", isOn: $options.hideProjects)
                if !options.card {
                    Toggle("Hide session titles", isOn: $options.hideSessions)
                    Toggle("Hide commit messages", isOn: $options.hideCommits)
                }
            }
            group("Look") {
                Picker("", selection: $options.dark) {
                    Text("Dark").tag(true)
                    Text("Light").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !options.card {
                    Picker("", selection: $options.wide) {
                        Text("Wide").tag(true)
                        Text("Narrow").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private var sections: some View {
            group("Sections") {
                Toggle("Summary numbers", isOn: $options.summary)
                Toggle("Year calendar", isOn: $options.calendar)
                if options.calendar {
                    Picker("", selection: $options.calendarTokens) {
                        Text("Time").tag(false)
                        Text("Tokens").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .padding(.leading, 20)
                }
                Toggle("Token bubbles", isOn: $options.bubbles)
                Toggle(model.snapshot.hourly ? "Minutes an hour" : "Hours a day", isOn: $options.hours)
                Toggle("Projects table", isOn: $options.projects)
                Toggle("Longest sessions", isOn: $options.sessions)
                Toggle("Commits", isOn: $options.commits)
            }
    }

    private var projectList: some View {
        let projects = model.snapshot.projects
        let excluded = Set(options.excluded)
        return group("Projects") {
            if projects.isEmpty {
                Text("No projects \(model.range.phrase).").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button("All") { options.excluded.removeAll { id in projects.contains { $0.id == id } } }
                    Button("None") { options.excluded = Array(excluded.union(projects.map(\.id))) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                ForEach(projects) { project in
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(project.id) },
                        set: { on in
                            if on { options.excluded.removeAll { $0 == project.id } } else { options.excluded.append(project.id) }
                        })) {
                        HStack(spacing: 6) {
                            Circle().fill(project.color).frame(width: 7, height: 7)
                            Text(project.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(StatsStyle.duration(project.total)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        ScrollView {
            Group {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: options.card ? 760 : options.width)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                } else {
                    ProgressView().padding(.top, 120)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.primary.opacity(0.06))
    }

    // MARK: Ways out

    private var actions: some View {
        HStack(spacing: 8) {
            if let status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button("Copy Markdown") { copyMarkdown() }
            Button("Copy Image") { copyImage() }
            Button("Save PDF…") { save(pdf: true) }
            Button("Save PNG…") { save(pdf: false) }
            Button { share() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                .background(AnchorView(anchor: anchor))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var data: ReportData { ReportData(model: model, options: options) }

    private func say(_ text: String) {
        withAnimation { status = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { if status == text { status = nil } } }
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(data.markdown(options), forType: .string)
        say("Markdown copied")
    }

    private func copyImage() {
        guard let png = ReportExport.png(data, options) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let image = NSImage(data: png), let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        say("Image copied")
    }

    private func save(pdf: Bool) {
        let data = data, options = options
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        panel.nameFieldStringValue = ReportExport.fileName(options, data, pdf ? "pdf" : "png")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let file = pdf ? ReportExport.pdf(data, options) : ReportExport.png(data, options) else { return }
                do {
                    try file.write(to: url, options: .atomic)
                    say("Saved \(url.lastPathComponent)")
                } catch {
                    say("Couldn't save: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The system's share menu (Mail, Messages, AirDrop, Notes…) with the picture.
    private func share() {
        let data = data
        guard let png = ReportExport.png(data, options), let view = anchor.view else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("omux-report", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ReportExport.fileName(options, data, "png"))
        guard (try? png.write(to: url, options: .atomic)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
}
