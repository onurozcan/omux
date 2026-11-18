import SwiftUI
import OmuxCore

// Home: one screen for every project. What waits for you, what is at work, a to-do list
// whose items can be sent to a session, and what the agents did this week.

/// Something to do, kept across launches. Sent to a session, it remembers which.
struct HomeTodo: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var created = Date()
    /// The session it was sent to, and when.
    var sentTo: UUID?
    var sentAt: Date?
}

@MainActor
final class HomeState: ObservableObject {
    static let shared = HomeState()
    /// Home is on show in place of the session.
    @Published var shown = false
    @Published private(set) var todos: [HomeTodo] = HomeState.load() {
        didSet { if let data = try? JSONEncoder().encode(todos) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }
    /// To-dos on their way to a session that is still starting.
    @Published private(set) var sending: Set<UUID> = []
    @Published var notice: String?
    @Published private(set) var stats: HomeStats?

    private static let key = "homeTodos"
    private var statsRead: Date?

    private static func load() -> [HomeTodo] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([HomeTodo].self, from: $0) } ?? []
    }

    func add(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        todos.insert(HomeTodo(text: text), at: 0)
    }

    func toggle(_ id: UUID) { change(id) { $0.done.toggle() } }
    func remove(_ id: UUID) { todos.removeAll { $0.id == id } }
    func clearDone() { todos.removeAll(where: \.done) }

    private func change(_ id: UUID, _ mutate: (inout HomeTodo) -> Void) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&todos[index])
    }

    /// Sends a to-do to a session as a prompt, starting the session's agent first when it has none.
    func send(_ todo: HomeTodo, to tabID: UUID, store: Store) {
        guard !sending.contains(todo.id) else { return }
        sending.insert(todo.id)
        notice = nil
        let name = store.tab(tabID)?.name ?? "the session"
        store.deliver(todo.text, to: tabID) { [weak self] sent in
            guard let self else { return }
            self.sending.remove(todo.id)
            if sent {
                self.change(todo.id) { $0.sentTo = tabID; $0.sentAt = Date() }
            } else {
                self.notice = "\(name) didn't take the to-do. It is in that session's message box."
            }
        }
    }

    /// A new session in the project, with the to-do as its first prompt. Home stays on show.
    func sendToNewSession(_ todo: HomeTodo, in groupID: UUID, store: Store) {
        guard let id = store.newTab(in: groupID) else {
            notice = "The session wasn't created: the project asked for something first. Send the to-do once it's there."
            return
        }
        shown = true
        send(todo, to: id, store: store)
    }

    /// Reads the week's conversations again, at most once a minute.
    func refreshStats(store: Store) {
        if let statsRead, Date().timeIntervalSince(statsRead) < 60 { return }
        statsRead = Date()
        let folders = store.groups.compactMap { group in
            group.directory.map { (name: group.name, path: (($0 as NSString).expandingTildeInPath as NSString).standardizingPath) }
        }
        Task.detached(priority: .utility) {
            let stats = HomeStats.read(projects: folders)
            await MainActor.run { self.stats = stats }
        }
    }
}

extension Store {
    /// Types a prompt into a session from outside it. An agent at its prompt takes it now; a
    /// stopped session is started the way ▶ does and gets it once its agent is up. `done` says
    /// whether it was typed; when it wasn't, the text is left in the session's message box.
    func deliver(_ text: String, to id: UUID, done: @escaping @MainActor (Bool) -> Void) {
        func ready() -> Bool {
            guard let rt = runtime[id], !rt.exited else { return false }
            return TranscriptPanel.takesInput(rt) && (rt.provider != .codex || rt.tuiReady)
        }
        if ready() { done(sendText(text, to: id, submit: true)); return }
        guard terminal(for: id) != nil else { done(false); return }
        start(id)
        Task { @MainActor in
            var promptShown = 0, idle = 0
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                guard tab(id) != nil else { done(false); return }
                guard let rt = runtime[id], !rt.exited else { continue }
                if rt.statusState == .error { break }
                // A resumed Claude Code sometimes never reports: its prompt box, steady on the
                // screen for five seconds, is then taken as the sign it is up.
                if rt.provider != .codex, shellRunsAgent(id), ClaudeScreen.showsPrompt(screenLines(id, count: 14)) { promptShown += 1 } else { promptShown = 0 }
                if ready() || promptShown >= 10 {
                    try? await Task.sleep(for: .seconds(1))
                    done(sendText(text, to: id, submit: true))
                    return
                }
                // Nothing in the shell and nothing on its way: the start is asked for once more.
                idle = shellRunsAgent(id) || isStarting(id) ? 0 : idle + 1
                if idle == 6 { start(id) }
            }
            ComposeDrafts.text[id] = text
            ComposeDrafts.version += 1
            done(false)
        }
    }
}

// MARK: Stats

/// What Claude Code's conversations of the last seven days add up to, read from their
/// transcript files: prompts you sent and tokens the agents wrote, by day and by project.
struct HomeStats: Sendable {
    struct Day: Sendable, Identifiable {
        let date: Date
        var prompts = 0
        var tokens = 0
        var conversations = 0
        /// Tokens written, by model id.
        var models: [String: Int] = [:]
        var id: Date { date }
    }
    struct Model: Sendable, Identifiable {
        let id: String
        let codex: Bool
        var tokens = 0
        var name: String { HomeStats.modelName(id) }
    }
    struct Project: Sendable, Identifiable {
        let name: String
        var prompts = 0
        var tokens = 0
        var id: String { name }
    }
    var days: [Day]
    var projects: [Project]
    /// The model ids that came from Codex's sessions; the others are Claude Code's.
    var codexModels: Set<String> = []

    /// The models that wrote on these days, the busiest first.
    func models(in days: [Day]) -> [Model] {
        var sum: [String: Int] = [:]
        for day in days { for (id, tokens) in day.models { sum[id, default: 0] += tokens } }
        return sum.filter { $0.value > 0 }.map { Model(id: $0.key, codex: codexModels.contains($0.key), tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
    }
    var weekModels: [Model] { models(in: days) }
    var todayModels: [Model] { models(in: [today]) }

    /// "Claude Code", "Codex" or both, by which wrote on these days. Claude Code when neither did.
    static func agents(of models: [Model]) -> String {
        let claude = models.contains { !$0.codex }, codex = models.contains(where: \.codex)
        return claude && codex ? "Claude Code and Codex" : codex ? "Codex" : "Claude Code"
    }

    /// "claude-opus-5-5" → "Opus 5.5", "gpt-5.6-luna" → "GPT-5.6 Luna".
    static func modelName(_ id: String) -> String {
        guard id.lowercased().hasPrefix("gpt") else { return TranscriptPanel.shortModel(id) }
        let parts = id.split(separator: "-").map(String.init)
        return (["GPT"] + parts.dropFirst().prefix(1)).joined(separator: "-")
            + parts.dropFirst(2).map { " " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    var today: Day { days.last ?? Day(date: Date()) }
    var weekPrompts: Int { days.reduce(0) { $0 + $1.prompts } }
    var weekTokens: Int { days.reduce(0) { $0 + $1.tokens } }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// What one transcript file holds, kept on disk so a file that hasn't changed isn't read again:
    /// a week of conversations runs to gigabytes.
    private struct FileStat: Codable {
        var modified: Double
        var size: Int
        var cwd: String?
        /// Days since the reference date → [prompts, tokens].
        var days: [String: [Int]]
        /// Days → model id → tokens.
        var models: [String: [String: Int]]?
    }

    private static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "net.pf1.omux").appendingPathComponent("home-stats-2.json")

    static func read(projects: [(name: String, path: String)]) -> HomeStats {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
        var days = (0..<7).map { Day(date: calendar.date(byAdding: .day, value: $0, to: start)!) }
        var byProject: [String: Project] = [:]
        // Longest folder first, so a project inside another's folder is its own.
        let folders = projects.sorted { $0.path.count > $1.path.count }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: FileStat].self, from: $0) } ?? [:]
        var kept: [String: FileStat] = [:]
        let key = { (date: Date) in String(Int(calendar.startOfDay(for: date).timeIntervalSinceReferenceDate)) }

        var codexModels: Set<String> = []
        func count(_ url: URL, codex: Bool) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified >= start else { return }
            let size = values?.fileSize ?? 0
            var stat: FileStat
            if let cached = cache[url.path], cached.modified == modified.timeIntervalSinceReferenceDate, cached.size == size {
                stat = cached
            } else {
                stat = codex ? scanCodex(url, since: start, key: key) : scan(url, since: start, key: key)
                stat.modified = modified.timeIntervalSinceReferenceDate
                stat.size = size
            }
            kept[url.path] = stat
            let name = stat.cwd.flatMap { cwd in folders.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }?.name } ?? "Other folders"
            for index in days.indices {
                let day = key(days[index].date)
                for (model, tokens) in stat.models?[day] ?? [:] {
                    days[index].models[model, default: 0] += tokens
                    if codex { codexModels.insert(model) }
                }
                guard let counts = stat.days[day], counts.count == 2 else { continue }
                days[index].prompts += counts[0]
                days[index].tokens += counts[1]
                if counts[0] > 0 { days[index].conversations += 1 }
                byProject[name, default: Project(name: name)].prompts += counts[0]
                byProject[name, default: Project(name: name)].tokens += counts[1]
            }
        }
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for url in files where url.pathExtension == "jsonl" { count(url, codex: false) }
        }
        // Codex keeps a file a session under sessions/<year>/<month>/<day>.
        let codexRoot = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
        if let walk = fm.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for case let url as URL in walk where url.pathExtension == "jsonl" { count(url, codex: true) }
        }
        cache = kept
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        return HomeStats(days: days, projects: byProject.values.filter { $0.prompts > 0 || $0.tokens > 0 }.sorted { $0.tokens > $1.tokens },
                         codexModels: codexModels)
    }

    /// Reads one Codex session: a turn started is a prompt, and each token count adds what was
    /// written since the one before, under the model the turn ran on.
    private static func scanCodex(_ url: URL, since start: Date, key: (Date) -> String) -> FileStat {
        var stat = FileStat(modified: 0, size: 0, cwd: nil, days: [:], models: [:])
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return stat }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let marks = [#""token_count""#, #""turn_context""#, #""task_started""#, #""session_meta""#].map { Array($0.utf8) }
        var model = "codex", written = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let rest = raw.count - offset
                let line = base + offset
                let length = memchr(line, 0x0A, rest).map { line.distance(to: UnsafeRawPointer($0)) } ?? rest
                defer { offset += length + 1 }
                guard length > 0, marks.contains(where: { memmem(line, length, $0, $0.count) != nil }),
                      let record = try? JSONSerialization.jsonObject(with: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any] else { continue }
                let date = (record["timestamp"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
                let counted = date.map { $0 >= start } ?? false
                switch (record["type"] as? String, payload["type"] as? String) {
                case ("session_meta", _): stat.cwd = payload["cwd"] as? String
                case ("turn_context", _): if let name = payload["model"] as? String { model = name }
                case ("event_msg", "task_started"):
                    if counted, let date { stat.days[key(date), default: [0, 0]][0] += 1 }
                case ("event_msg", "token_count"):
                    guard let info = payload["info"] as? [String: Any],
                          let total = (info["total_token_usage"] as? [String: Any])?["output_tokens"] as? Int else { continue }
                    // The total starts over after a compaction: then the last turn's count is what was added.
                    let added = total >= written ? total - written : ((info["last_token_usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0)
                    written = total
                    guard counted, let date, added > 0 else { continue }
                    stat.days[key(date), default: [0, 0]][1] += added
                    stat.models?[key(date), default: [:]][model, default: 0] += added
                default: continue
                }
            }
        }
        return stat
    }

    /// Reads one transcript: only the lines that can count are parsed, found by their bytes.
    private static func scan(_ url: URL, since start: Date, key: (Date) -> String) -> FileStat {
        var stat = FileStat(modified: 0, size: 0, cwd: nil, days: [:], models: [:])
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return stat }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        // A reply is written as several records with the same usage: counted once, by its id.
        var replies: [String: (day: String, tokens: Int, model: String)] = [:]
        let tokens = Array(#""output_tokens""#.utf8), user = Array(#""type":"user""#.utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let rest = raw.count - offset
                let line = base + offset
                let length = memchr(line, 0x0A, rest).map { line.distance(to: UnsafeRawPointer($0)) } ?? rest
                defer { offset += length + 1 }
                guard length > 0, memmem(line, length, tokens, tokens.count) != nil || memmem(line, length, user, user.count) != nil,
                      let record = try? JSONSerialization.jsonObject(with: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)) as? [String: Any],
                      record["isSidechain"] as? Bool != true,
                      let stamp = record["timestamp"] as? String,
                      let date = formatter.date(from: stamp) ?? plain.date(from: stamp), date >= start else { continue }
                if stat.cwd == nil { stat.cwd = record["cwd"] as? String }
                let day = key(date)
                let message = record["message"] as? [String: Any]
                switch record["type"] as? String {
                case "assistant":
                    guard let id = message?["id"] as? String, let usage = message?["usage"] as? [String: Any],
                          let count = usage["output_tokens"] as? Int else { continue }
                    replies[id] = (day, max(count, replies[id]?.tokens ?? 0), message?["model"] as? String ?? "claude")
                case "user":
                    guard record["isMeta"] as? Bool != true, isPrompt(message?["content"]) else { continue }
                    stat.days[day, default: [0, 0]][0] += 1
                default: continue
                }
            }
        }
        for reply in replies.values where reply.tokens > 0 {
            stat.days[reply.day, default: [0, 0]][1] += reply.tokens
            stat.models?[reply.day, default: [:]][reply.model, default: 0] += reply.tokens
        }
        return stat
    }

    /// A user record that is something you typed: not a tool's result, and not Claude Code's
    /// own wrapping of a command or its output.
    private static func isPrompt(_ content: Any?) -> Bool {
        if let text = content as? String { return !text.hasPrefix("<") && !text.isEmpty }
        guard let blocks = content as? [[String: Any]] else { return false }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
        return blocks.contains { ($0["type"] as? String) == "text" && !(($0["text"] as? String) ?? "<").hasPrefix("<") }
    }
}

// MARK: The screen

struct HomeView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var home = HomeState.shared
    @ObservedObject private var pulls = PullRequestMonitor.shared
    let theme: Theme
    @State private var draft = ""
    @FocusState private var adding: Bool
    @State private var sharing = false

    private var sessions: [(tab: TabItem, group: TabGroup, rt: TabRuntime)] {
        store.allTabs.map { ($0.tab, $0.group, store.runtime[$0.tab.id] ?? TabRuntime()) }
    }
    private var waiting: [(tab: TabItem, group: TabGroup, rt: TabRuntime)] {
        sessions.filter { $0.rt.statusState == .blocked || $0.rt.statusState == .error || $0.rt.needsAttention }
    }
    private var working: [(tab: TabItem, group: TabGroup, rt: TabRuntime)] {
        sessions.filter { $0.rt.statusState == .working }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let notice = home.notice {
                    Text(notice).font(.system(size: 11.5)).foregroundStyle(Palette.needs)
                }
                // Two columns with room for them, one under the other without.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) { needsYou; todo; workingNow }.frame(minWidth: 380, maxWidth: .infinity)
                        VStack(spacing: 14) { stats; limits; pullRequests }.frame(width: 360)
                    }
                    VStack(spacing: 14) { needsYou; todo; workingNow; stats; limits; pullRequests }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: theme.background))
        .onAppear { home.refreshStats(store: store) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Home").font(.system(size: 22, weight: .semibold))
            Text(summary).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let open = home.todos.filter { !$0.done }.count
        var parts = [Date().formatted(.dateTime.weekday(.wide).day().month(.wide))]
        parts.append(waiting.isEmpty ? "nothing waits for you" : "\(waiting.count) waiting for you")
        if !working.isEmpty { parts.append("\(working.count) at work") }
        if open > 0 { parts.append("\(open) to do") }
        return parts.joined(separator: " · ")
    }

    // MARK: Sessions

    private var needsYou: some View {
        HomeCard(title: "Needs you", icon: "bell", count: waiting.count, tint: Palette.needs) {
            if waiting.isEmpty {
                HomeEmpty(text: "No session is waiting. A permission, a question or a finished turn shows here.")
            } else {
                ForEach(waiting, id: \.tab.id) { item in
                    HomeSessionRow(tab: item.tab, group: item.group, buttons: true)
                }
            }
        }
    }

    private var workingNow: some View {
        HomeCard(title: "Working now", icon: "bolt", count: working.count, tint: Palette.working) {
            if working.isEmpty {
                HomeEmpty(text: "No agent is at work.")
            } else {
                ForEach(working, id: \.tab.id) { item in
                    HomeSessionRow(tab: item.tab, group: item.group, buttons: false)
                }
            }
        }
    }

    // MARK: To-do

    private var todo: some View {
        let open = home.todos.filter { !$0.done }
        let done = home.todos.filter(\.done)
        return HomeCard(title: "To do", icon: "checklist", count: open.count, tint: .secondary) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                TextField("Add something to do, then send it to a session", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($adding)
                    .onSubmit { home.add(draft); draft = ""; adding = true }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ForEach(open) { item in HomeTodoRow(todo: item) }
            if !done.isEmpty {
                HStack {
                    Text("Done").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear") { home.clearDone() }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                ForEach(done) { item in HomeTodoRow(todo: item) }
            }
        }
    }

    // MARK: Stats

    private var stats: some View {
        HomeCard(title: "This week", icon: "chart.bar", count: 0, tint: .secondary) {
            if let stats = home.stats {
                HStack(spacing: 0) {
                    HomeFigure(value: "\(stats.today.prompts)", label: "prompts today")
                    HomeFigure(value: HomeStats.compact(stats.today.tokens), label: "tokens today")
                    HomeFigure(value: "\(stats.weekPrompts)", label: "prompts · 7d")
                    HomeFigure(value: HomeStats.compact(stats.weekTokens), label: "tokens · 7d")
                }
                let top = max(stats.days.map(\.tokens).max() ?? 0, 1)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(stats.days) { day in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Calendar.current.isDateInToday(day.date) ? Palette.working : Color.primary.opacity(0.22))
                                .frame(height: max(2, 54 * CGFloat(day.tokens) / CGFloat(top)))
                            Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(day.date.formatted(.dateTime.weekday(.wide).day().month())): \(day.prompts) prompts, \(HomeStats.compact(day.tokens)) tokens out, \(day.conversations) conversations")
                    }
                }
                .frame(height: 72, alignment: .bottom)
                .padding(.top, 6)
                if !stats.projects.isEmpty {
                    let most = max(stats.projects.first?.tokens ?? 0, 1)
                    VStack(spacing: 5) {
                        ForEach(stats.projects.prefix(6)) { project in
                            HStack(spacing: 8) {
                                Text(project.name).font(.system(size: 11.5)).lineLimit(1).frame(width: 110, alignment: .leading)
                                GeometryReader { geo in
                                    Capsule().fill(.primary.opacity(0.2)).frame(width: max(2, geo.size.width * CGFloat(project.tokens) / CGFloat(most)))
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 5)
                                Text("\(project.prompts) · \(HomeStats.compact(project.tokens))")
                                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 78, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                let models = stats.weekModels
                if !models.isEmpty {
                    let most = max(models.first?.tokens ?? 0, 1)
                    let all = max(models.reduce(0) { $0 + $1.tokens }, 1)
                    VStack(spacing: 5) {
                        ForEach(models.prefix(5)) { model in
                            HStack(spacing: 8) {
                                HStack(spacing: 5) {
                                    ProviderLogo(provider: model.codex ? .codex : .claude, size: 10).foregroundStyle(.secondary)
                                    Text(model.name).font(.system(size: 11.5)).lineLimit(1)
                                }
                                .frame(width: 110, alignment: .leading)
                                GeometryReader { geo in
                                    Capsule().fill(.primary.opacity(0.2)).frame(width: max(2, geo.size.width * CGFloat(model.tokens) / CGFloat(most)))
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 5)
                                Text((model.tokens * 100 / all < 1 ? "<1" : "\(model.tokens * 100 / all)") + "% · \(HomeStats.compact(model.tokens))")
                                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 78, alignment: .trailing)
                            }
                            .help("\(model.id): \(model.tokens.formatted()) tokens written in the last 7 days")
                        }
                    }
                    .padding(.top, 8)
                }
                Text("Claude Code and Codex conversations on this Mac. Prompts and tokens written, by project and by model.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 4)
            } else {
                HomeEmpty(text: "Reading this week's conversations…")
            }
        }
        .overlay(alignment: .topTrailing) {
            if let stats = home.stats {
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 11.5, weight: .medium)) }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Share today's or this week's figures as a picture")
                    .padding(9)
                    .popover(isPresented: $sharing, arrowEdge: .bottom) { ShareCardPanel(stats: stats) }
            }
        }
    }

    private var limits: some View {
        HomeCard(title: "Limits", icon: "gauge.with.dots.needle.33percent", count: 0, tint: .secondary) {
            UsageView(provider: .claude)
            // Codex's limits too, once it has been signed in to on this Mac.
            if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json") {
                UsageView(provider: .codex)
            }
        }
    }

    private var pullRequests: some View {
        let open = store.allTabs.compactMap { item in pulls.requests[item.tab.id].map { (tab: item.tab, pr: $0) } }.filter { $0.pr.state == .open }
        return HomeCard(title: "Pull requests", icon: "arrow.triangle.pull", count: open.count, tint: .secondary) {
            if open.isEmpty {
                HomeEmpty(text: "No session has an open pull request.")
            } else {
                ForEach(open, id: \.tab.id) { item in
                    Button { store.selectedTabID = item.tab.id } label: {
                        HStack(spacing: 8) {
                            Circle().fill(item.pr.color).frame(width: 6, height: 6)
                            Text("#\(item.pr.number)").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            Text(item.pr.title).font(.system(size: 11.5)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(item.pr.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Go to \(item.tab.name)")
                }
            }
        }
    }
}

/// One session on Home: its dot, its name and project, what it says, and Allow / Deny when
/// that is what it waits for. A click goes to it.
private struct HomeSessionRow: View {
    @EnvironmentObject var store: Store
    let tab: TabItem
    let group: TabGroup
    let buttons: Bool
    @State private var hovering = false

    var body: some View {
        WithRuntime(tab.id) { rt in
            HStack(spacing: 9) {
                StatusDot(color: rt.statusColor ?? Color.secondary.opacity(0.4), pulsing: rt.statusState == .working, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(tab.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(group.name).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Text(rt.statusLine(showFolder: false) ?? "Finished").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if buttons, rt.awaitsPermission { PermissionButtons(tabID: tab.id).controlSize(.small) }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { store.selectedTabID = tab.id }
            .onHover { hovering = $0 }
        }
    }
}

private struct HomeTodoRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var home = HomeState.shared
    let todo: HomeTodo
    @State private var hovering = false

    var body: some View {
        let sending = home.sending.contains(todo.id)
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button { home.toggle(todo.id) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(todo.done ? AnyShapeStyle(Palette.done) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.text)
                    .font(.system(size: 12.5))
                    .strikethrough(todo.done)
                    .foregroundStyle(todo.done ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if sending {
                    Text("Starting the session, then sending…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else if let id = todo.sentTo, let tab = store.tab(id) {
                    Button { store.selectedTabID = id } label: {
                        Text("Sent to \(tab.name)" + (todo.sentAt.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                            .font(.system(size: 10.5)).foregroundStyle(Palette.working)
                    }
                    .buttonStyle(.plain)
                    .help("Go to the session")
                }
            }
            Spacer(minLength: 6)
            if !todo.done, !sending {
                Menu {
                    ForEach(store.groups) { group in
                        Section(group.name) {
                            ForEach(group.tabs.filter { [.claude, .codex].contains(store.transcriptProvider(of: $0)) }) { tab in
                                Button(tab.name) { home.send(todo, to: tab.id, store: store) }
                            }
                            Button("New session in \(group.name)") { home.sendToNewSession(todo, in: group.id, store: store) }
                        }
                    }
                } label: {
                    Label("Send", systemImage: "paperplane").font(.system(size: 11))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Send this to a session as a prompt")
            }
            Button { home.remove(todo.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(hovering ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// A titled sheet on Home, in the cards' own style.
private struct HomeCard<Content: View>: View {
    let title: String
    let icon: String
    let count: Int
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if count > 0 {
                    Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(tint.opacity(0.18), in: Capsule())
                }
                Spacer()
            }
            .padding(.bottom, 2)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }
}

private struct HomeEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    }
}

private struct HomeFigure: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
