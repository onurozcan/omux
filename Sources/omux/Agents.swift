import AppKit
import SwiftUI

/// A Claude Code subagent of one session. Claude Code writes each one to
/// ~/.claude/projects/<project>/<session>/subagents/agent-<id>.meta.json, with its
/// transcript next to it as agent-<id>.jsonl.
struct SubAgent: Identifiable, Equatable {
    let id: String
    let type: String
    let description: String
    let background: Bool
    let depth: Int
    var finished: Bool
    let started: Date
    var ended: Date?
    let transcript: URL
    var activity: String?
    var toolCount: Int
    /// Set from the session's OSC 7501 child records when one matches this agent.
    var blocked = false

    var elapsedText: String {
        let seconds = Int(max(0, (ended ?? Date()).timeIntervalSince(started)))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var color: Color { blocked ? Palette.needs : finished ? Palette.done : Palette.working }

    /// The tool it's using, for tight spaces: "Grep".
    var shortActivity: String {
        if blocked { return "needs you" }
        if finished { return "done" }
        return activity?.split(separator: " ").first.map(String.init) ?? "starting"
    }
}

struct AgentRef: Equatable {
    let tabID: UUID
    let agentID: String
    let type: String
    let description: String
    let transcript: URL

    init(tabID: UUID, agent: SubAgent) {
        self.tabID = tabID
        agentID = agent.id
        type = agent.type
        description = agent.description
        transcript = agent.transcript
    }
}

/// Watches the subagent folders of running sessions.
@MainActor
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    /// Agents worth showing per session: running ones, and finished ones for a short while.
    @Published private(set) var agents: [UUID: [SubAgent]] = [:]
    private let scanner = AgentScanner()
    private let queue = DispatchQueue(label: "omux.agents", qos: .utility)
    private var scanning = false
    /// Something changed while a scan was in flight: scan again as soon as it lands.
    private var rescanWanted = false
    /// A safety net behind the watchers, for a file system that doesn't report changes.
    private var timer: Timer?
    /// When an agent without a "finished" mark was first seen with its session idle.
    private var stopped: [String: Date] = [:]
    /// The folders and files whose changes mean another look: by path.
    private var watchers: [String: PathWatcher] = [:]
    private var pollScheduled = false
    /// Takes a finished agent off the list when its time is up.
    private var expiry: Task<Void, Never>?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in AgentMonitor.shared.poll() }
        }
    }

    /// A look soon, once; the writes behind one event tend to come in a burst.
    func schedulePoll() {
        guard !pollScheduled else { return }
        pollScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.pollScheduled = false
            self.poll()
        }
    }

    func poll() {
        if scanning { rescanWanted = true; return }
        let store = Store.shared
        var sessions: [AgentScanner.Session] = []
        var children: [UUID: [TabRuntime.StatusChild]] = [:]
        var working: Set<UUID> = []
        for entry in store.allTabs {
            guard store.provider(of: entry.tab) == .claude else { continue }
            let rt = store.runtime[entry.tab.id] ?? TabRuntime()
            let active = !rt.exited && (rt.busy || rt.statusState == .working || rt.statusState == .blocked)
            guard active || agents[entry.tab.id] != nil else { continue }
            sessions.append(.init(tab: entry.tab.id, session: entry.tab.claudeSessionID.uuidString.lowercased(), active: active,
                                  project: store.claudeProjectFolderURL(for: entry.tab.id)))
            children[entry.tab.id] = rt.statusChildren
            if rt.statusState == .working || rt.statusState == .blocked { working.insert(entry.tab.id) }
        }
        guard !sessions.isEmpty || !agents.isEmpty else { return }
        scanning = true
        let scanner = self.scanner
        queue.async {
            let (found, watch) = scanner.scan(sessions)
            DispatchQueue.main.async {
                self.scanning = false
                if self.rescanWanted { self.rescanWanted = false; self.schedulePoll() }
                self.watch(watch)
                var result: [UUID: [SubAgent]] = [:]
                let now = Date()
                for (tab, list) in found {
                    let kids = children[tab] ?? []
                    let blocked = kids.filter { $0.state == .blocked }
                    result[tab] = list.compactMap { agent in
                        var agent = agent
                        // An agent stopped with TaskStop never writes "finished": once its
                        // session is idle and Claude Code lists no such child, it's over.
                        if !agent.finished, !working.contains(tab), !kids.contains(where: { Self.matches($0, agent) }) {
                            let since = self.stopped[agent.id] ?? now
                            self.stopped[agent.id] = since
                            if now.timeIntervalSince(since) > AgentScanner.lingerForeground { return nil }
                            agent.finished = true
                            agent.ended = since
                        }
                        agent.blocked = !agent.finished && blocked.contains { Self.matches($0, agent) }
                        return agent
                    }
                    if result[tab]?.isEmpty == true { result[tab] = nil }
                }
                self.stopped = self.stopped.filter { now.timeIntervalSince($0.value) < 3600 }
                if result != self.agents { self.agents = result }
                self.scheduleExpiry(of: result, now: now)
            }
        }
    }

    /// Watches exactly these paths, dropping the rest. A folder that doesn't exist yet is
    /// skipped; its parent is in the set, and tells when it appears.
    private func watch(_ paths: Set<String>) {
        for path in watchers.keys where !paths.contains(path) { watchers[path] = nil }
        for path in paths where watchers[path] == nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            watchers[path] = PathWatcher(path: path, directory: isDirectory.boolValue) { [weak self] in self?.schedulePoll() }
        }
    }

    /// Finished agents leave the list on their own clock, which no file event announces.
    private func scheduleExpiry(of agents: [UUID: [SubAgent]], now: Date) {
        expiry?.cancel(); expiry = nil
        let ends = agents.values.flatMap { $0 }.compactMap { agent -> Date? in
            guard agent.finished, let ended = agent.ended else { return nil }
            return ended.addingTimeInterval(agent.background ? AgentScanner.lingerBackground : AgentScanner.lingerForeground)
        }
        guard let soonest = ends.min() else { return }
        let wait = max(0.2, soonest.timeIntervalSince(now) + 0.1)
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self.poll()
        }
    }

    /// Whether an OSC 7501 child record describes this agent: by id, or by the
    /// description it was launched with.
    private static func matches(_ child: TabRuntime.StatusChild, _ agent: SubAgent) -> Bool {
        let short = agent.id.replacingOccurrences(of: "agent-", with: "")
        if child.id.contains(short) { return true }
        return [child.title, child.message].contains { $0?.localizedCaseInsensitiveContains(agent.description) == true }
    }
}

/// The file work behind AgentMonitor. Used only on the monitor's queue.
/// Only ever used on AgentMonitor's serial queue.
private final class AgentScanner: @unchecked Sendable {
    struct Session {
        let tab: UUID
        let session: String
        let active: Bool
        /// The ~/.claude/projects folder the session's files appear under, when known.
        let project: URL?
    }

    private struct Meta: Decodable {
        var agentType: String?
        var description: String?
        var requestShape: String?
        var spawnDepth: Int?
        var finished: Bool?
    }

    private struct Progress {
        var offset: UInt64 = 0
        var remainder = Data()
        var tools = 0
        var activity: String?
    }

    /// How long a finished agent stays listed.
    static let lingerForeground: TimeInterval = 20
    static let lingerBackground: TimeInterval = 120

    private var folders: [String: URL] = [:]
    private var misses: [String: Date] = [:]
    private var progress: [String: Progress] = [:]

    /// The agents per session, and the paths whose changes call for another scan: the subagents
    /// folder and the files of agents still running, or, before the folder exists, the nearest
    /// folder on the way to it.
    func scan(_ sessions: [Session]) -> (agents: [UUID: [SubAgent]], watch: Set<String>) {
        var result: [UUID: [SubAgent]] = [:]
        var watch: Set<String> = []
        for session in sessions {
            guard let folder = folder(for: session.session) else {
                if let project = session.project {
                    let sessionDir = project.appendingPathComponent(session.session)
                    watch.insert(FileManager.default.fileExists(atPath: sessionDir.path) ? sessionDir.path : project.path)
                }
                continue
            }
            watch.insert(folder.path)
            let agents = agents(in: folder, active: session.active)
            for agent in agents where !agent.finished {
                watch.insert(agent.transcript.path)
                watch.insert(folder.appendingPathComponent(agent.id + ".meta.json").path)
            }
            if !agents.isEmpty { result[session.tab] = agents }
        }
        return (result, watch)
    }

    /// The session's subagents folder; it appears with the first subagent.
    private func folder(for session: String) -> URL? {
        if let folder = folders[session] { return folder }
        if let miss = misses[session], Date().timeIntervalSince(miss) < 3 { return nil }
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let folder = projects.appendingPathComponent(name).appendingPathComponent(session).appendingPathComponent("subagents")
            if FileManager.default.fileExists(atPath: folder.path) {
                folders[session] = folder
                return folder
            }
        }
        misses[session] = Date()
        return nil
    }

    private func agents(in folder: URL, active: Bool) -> [SubAgent] {
        let fm = FileManager.default
        let now = Date()
        var agents: [SubAgent] = []
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".meta.json") {
            let id = String(name.dropLast(".meta.json".count))
            let metaURL = folder.appendingPathComponent(name)
            let transcript = folder.appendingPathComponent(id + ".jsonl")
            let metaDate = modified(metaURL) ?? .distantPast
            let transcriptDate = modified(transcript) ?? metaDate
            // Old agents are skipped by date alone, without opening their files: a running
            // agent keeps writing its transcript, a finished one only lingers briefly.
            let recentlyWritten = now.timeIntervalSince(transcriptDate) < 1800
            guard now.timeIntervalSince(metaDate) < Self.lingerBackground || (active && recentlyWritten) else { continue }
            guard let data = fm.contents(atPath: metaURL.path), let meta = try? JSONDecoder().decode(Meta.self, from: data) else { continue }
            let finished = meta.finished ?? false
            let background = meta.requestShape == "background"
            if finished {
                let linger = background ? Self.lingerBackground : Self.lingerForeground
                guard now.timeIntervalSince(metaDate) < linger else { continue }
            } else {
                guard active, recentlyWritten else { continue }
            }
            var state = progress[transcript.path] ?? Progress()
            read(transcript, into: &state)
            progress[transcript.path] = state
            let started = (try? fm.attributesOfItem(atPath: transcript.path)[.creationDate] as? Date) ?? metaDate
            agents.append(SubAgent(
                id: id,
                type: meta.agentType ?? "agent",
                description: meta.description ?? id,
                background: background,
                depth: max(1, meta.spawnDepth ?? 1),
                finished: finished,
                started: started,
                ended: finished ? metaDate : nil,
                transcript: transcript,
                activity: state.activity,
                toolCount: state.tools
            ))
        }
        return agents.sorted { $0.started < $1.started }
    }

    private func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Reads only what was appended since last time, counting tool calls.
    private func read(_ url: URL, into state: inout Progress) {
        for object in Transcript.newObjects(url, offset: &state.offset, remainder: &state.remainder) {
            guard object["type"] as? String == "assistant",
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for item in content where item["type"] as? String == "tool_use" {
                state.tools += 1
                state.activity = Transcript.summary(name: item["name"] as? String ?? "Tool", input: item["input"] as? [String: Any] ?? [:])
            }
        }
    }
}

// MARK: - Transcript

enum Transcript {
    /// JSON objects for the complete lines appended after `offset`; a partial last line
    /// waits in `remainder` for the next read.
    static func newObjects(_ url: URL, offset: inout UInt64, remainder: inout Data) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let chunk = handle.readData(ofLength: Int(min(size - offset, 64 << 20)))
        offset += UInt64(chunk.count)
        let data = remainder + chunk
        guard let end = data.lastIndex(of: 0x0A) else { remainder = data; return [] }
        remainder = Data(data[data.index(after: end)...])
        return data[..<end].split(separator: 0x0A).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    /// "Grep "useTheme"", "Read src/app.tsx", "Bash npm test".
    static func summary(name: String, input: [String: Any]) -> String {
        var detail = ""
        if let command = input["command"] as? String {
            detail = command
        } else if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
            detail = (path as NSString).lastPathComponent
        } else if let pattern = input["pattern"] as? String {
            detail = "\"\(pattern)\""
        } else if let other = ["url", "query", "description", "prompt", "path"].lazy.compactMap({ input[$0] as? String }).first {
            detail = other
        }
        detail = detail.replacingOccurrences(of: "\n", with: " ")
        if detail.count > 90 { detail = String(detail.prefix(90)) + "…" }
        return detail.isEmpty ? name : "\(name) \(detail)"
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let items = content as? [[String: Any]] {
            return items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    enum Kind { case task, text, tool }
    let id: Int
    let kind: Kind
    var title: String
    var result: String?
    var isError = false
}

/// A subagent's transcript, read incrementally while it's open.
@MainActor
final class AgentTranscript: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    let url: URL
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var toolRows: [String: Int] = [:]
    private var loading = false
    /// The file changed while a read was in flight: read again as soon as it lands.
    private var reloadWanted = false
    private var timer: Timer?

    private enum Event {
        case task(String), text(String), tool(id: String, title: String), result(id: String, text: String, error: Bool)
    }

    /// Wakes on every append; the timer is a safety net behind it.
    private var watcher: PathWatcher?

    init(url: URL) {
        self.url = url
        load()
        watcher = PathWatcher(path: url.path) { [weak self] in self?.load() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    deinit { timer?.invalidate() }

    func load() {
        if loading { reloadWanted = true; return }
        loading = true
        let url = self.url
        var offset = self.offset
        var remainder = self.remainder
        let first = entries.isEmpty
        Task.detached {
            var events: [Event] = []
            var sawTask = !first
            for object in Transcript.newObjects(url, offset: &offset, remainder: &remainder) {
                let message = object["message"] as? [String: Any]
                switch object["type"] as? String {
                case "user":
                    // Claude Code's own reminders and notices, not the agent's conversation.
                    if object["isMeta"] as? Bool == true { continue }
                    if let items = message?["content"] as? [[String: Any]] {
                        for item in items {
                            switch item["type"] as? String {
                            case "tool_result":
                                let text = Transcript.text(of: item["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                                events.append(.result(id: item["tool_use_id"] as? String ?? "", text: text, error: item["is_error"] as? Bool ?? false))
                            case "text" where !sawTask:
                                // A fork's directive comes after the result of the call that started
                                // it, behind boilerplate every fork shares.
                                var text = item["text"] as? String ?? ""
                                if let end = text.range(of: "</fork-boilerplate>") { text = String(text[end.upperBound...]) }
                                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { continue }
                                events.append(.task(text))
                                sawTask = true
                            default:
                                break
                            }
                        }
                    } else if let text = message?["content"] as? String, !text.isEmpty {
                        events.append(sawTask ? .text(text) : .task(text))
                        sawTask = true
                    }
                case "assistant":
                    // A fork's transcript opens with its parent's call that spawned it.
                    guard sawTask else { continue }
                    for item in message?["content"] as? [[String: Any]] ?? [] {
                        switch item["type"] as? String {
                        case "text":
                            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { events.append(.text(text)) }
                        case "tool_use":
                            let title = Transcript.summary(name: item["name"] as? String ?? "Tool", input: item["input"] as? [String: Any] ?? [:])
                            events.append(.tool(id: item["id"] as? String ?? UUID().uuidString, title: title))
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
            let (read, rest, found) = (offset, remainder, events)
            await MainActor.run {
                self.offset = read
                self.remainder = rest
                self.apply(found)
                self.loading = false
                if self.reloadWanted { self.reloadWanted = false; self.load() }
            }
        }
    }

    private func apply(_ events: [Event]) {
        guard !events.isEmpty else { return }
        var list = entries
        for event in events {
            switch event {
            case .task(let text):
                list.append(TranscriptEntry(id: list.count, kind: .task, title: text))
            case .text(let text):
                list.append(TranscriptEntry(id: list.count, kind: .text, title: text))
            case .tool(let id, let title):
                toolRows[id] = list.count
                list.append(TranscriptEntry(id: list.count, kind: .tool, title: title))
            case .result(let id, let text, let error):
                guard let row = toolRows[id], list.indices.contains(row) else { continue }
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? "Done"
                list[row].result = firstLine.count > 140 ? String(firstLine.prefix(140)) + "…" : firstLine
                list[row].isError = error
            }
        }
        entries = list
    }
}

// MARK: - Views

/// A filled dot for foreground agents, a ring for background ones.
struct AgentDot: View {
    let agent: SubAgent
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .strokeBorder(agent.color, lineWidth: 1.5)
            .background(Circle().fill(agent.background ? Color.clear : agent.color))
            .frame(width: size, height: size)
    }
}

/// Indented rows under a session in the sidebar: every agent of the selected session,
/// and agents that need you in any session.
struct AgentRows: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = AgentMonitor.shared
    let tabID: UUID
    let selected: Bool
    @State private var showAll = false

    var body: some View {
        let all = monitor.agents[tabID] ?? []
        let visible = selected ? all : all.filter(\.blocked)
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(showAll ? visible : Array(visible.prefix(3))) { agent in
                    Button { store.openAgentTranscript(agent, in: tabID) } label: {
                        HStack(spacing: 6) {
                            AgentDot(agent: agent)
                            Text(agent.description).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(agent.shortActivity)
                                .font(.system(size: 10))
                                .foregroundStyle(agent.blocked ? Palette.needs : Color.secondary)
                        }
                        .padding(.leading, CGFloat(min(agent.depth, 3) - 1) * 10)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            store.openAgent?.agentID == agent.id ? Color.accentColor.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(agent.type) · \(agent.activity ?? "starting")")
                }
                if visible.count > 3 {
                    Button(showAll ? "Show less" : "+\(visible.count - 3) more") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 17)
                }
            }
            .font(.caption)
            .padding(.top, 3)
        }
    }
}

/// "●●● 3 agents" in the header strip; opens the list of the session's agents.
struct AgentPill: View {
    @ObservedObject private var monitor = AgentMonitor.shared
    let tabID: UUID
    @State private var open = false

    var body: some View {
        let agents = monitor.agents[tabID] ?? []
        if !agents.isEmpty {
            let running = agents.filter { !$0.finished }.count
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    HStack(spacing: 2) {
                        ForEach(agents.prefix(8)) { AgentDot(agent: $0, size: 6) }
                    }
                    Text(running == 0 ? "agents done" : "\(running) agent\(running == 1 ? "" : "s")")
                }
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(open ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Subagents in this session")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AgentList(tabID: tabID) { open = false }
            }
        }
    }
}

struct AgentList: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = AgentMonitor.shared
    let tabID: UUID
    let dismiss: () -> Void

    var body: some View {
        let agents = monitor.agents[tabID] ?? []
        let running = agents.filter { !$0.finished }.count
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Agents").font(.system(size: 12, weight: .semibold))
                Text("\(running) running · \(agents.count - running) done").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 2) {
                    ForEach(agents) { agent in
                        Button {
                            store.openAgentTranscript(agent, in: tabID)
                            dismiss()
                        } label: { row(agent) }
                            .buttonStyle(.plain)
                    }
                }
            }
            Text("Click an agent to open its transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        .padding(8)
        .frame(width: 400)
    }

    private func row(_ agent: SubAgent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AgentDot(agent: agent, size: 8)
                Text(agent.type)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Text(agent.description).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(agent.elapsedText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(agent.blocked ? "Needs permission" : agent.finished ? "Done" : agent.activity ?? "Starting…")
                    .foregroundStyle(agent.blocked ? Palette.needs : agent.finished ? Palette.done : Color.secondary)
                    .lineLimit(1)
                Text("· \(agent.toolCount) tool\(agent.toolCount == 1 ? "" : "s")")
                if agent.background { Text("· background") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(store.openAgent?.agentID == agent.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// A subagent's transcript, shown where the file preview usually is.
struct AgentTranscriptView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = AgentMonitor.shared
    @StateObject private var transcript: AgentTranscript
    let ref: AgentRef

    init(ref: AgentRef) {
        self.ref = ref
        _transcript = StateObject(wrappedValue: AgentTranscript(url: ref.transcript))
    }

    var body: some View {
        let live = monitor.agents[ref.tabID]?.first { $0.id == ref.agentID }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let live { AgentDot(agent: live, size: 8) }
                Text(ref.description).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(ref.type)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                if let live {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(live.elapsedText) · \(live.toolCount) tools").font(.caption2).monospacedDigit()
                    }
                }
                if live?.blocked == true, store.runtime[ref.tabID]?.awaitsPermission == true {
                    PermissionButtons(tabID: ref.tabID)
                }
                Button { store.openAgent = nil } label: { Image(systemName: "xmark") }
                    .help("Close transcript")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(transcript.entries) { entry(for: $0) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: transcript.entries.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func entry(for entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .task:
            VStack(alignment: .leading, spacing: 4) {
                Text("TASK").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(entry.title.count > 1500 ? String(entry.title.prefix(1500)) + "…" : entry.title)
                    .font(.system(size: 12))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .text:
            Text(entry.title.count > 3000 ? String(entry.title.prefix(3000)) + "…" : entry.title)
                .font(.system(size: 12))
        case .tool:
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(entry.isError ? Palette.error : entry.result == nil ? Palette.working : Palette.done)
                        .frame(width: 6, height: 6)
                    Text(entry.title).lineLimit(3)
                }
                Text("⎿  " + (entry.result ?? "Running…"))
                    .foregroundStyle(entry.isError ? Palette.error : entry.result == nil ? Palette.working : Color.secondary)
                    .lineLimit(2)
                    .padding(.leading, 12)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }
}
