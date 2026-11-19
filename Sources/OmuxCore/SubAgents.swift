import Foundation

/// A Claude Code subagent of one session. Claude Code writes each one to
/// ~/.claude/projects/<project>/<session>/subagents/agent-<id>.meta.json, with its
/// transcript next to it as agent-<id>.jsonl.
public struct SubAgent: Identifiable, Equatable {
    public let id: String
    public let type: String
    public let description: String
    public let background: Bool
    public let depth: Int
    public var finished: Bool
    public let started: Date
    public var ended: Date?
    public let transcript: URL
    public var activity: String?
    public var toolCount: Int
    /// Set from the session's OSC 7501 child records when one matches this agent.
    public var blocked = false

    public var elapsedText: String {
        let seconds = Int(max(0, (ended ?? Date()).timeIntervalSince(started)))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The tool it's using, for tight spaces: "Grep".
    public var shortActivity: String {
        if blocked { return "needs you" }
        if finished { return "done" }
        return activity?.split(separator: " ").first.map(String.init) ?? "starting"
    }
}

/// The file work behind AgentMonitor. Used only on the monitor's queue.
/// Only ever used on AgentMonitor's serial queue.
public final class AgentScanner: @unchecked Sendable {
    public struct Session {
        public let tab: UUID
        public let session: String
        public let active: Bool
        /// The ~/.claude/projects folder the session's files appear under, when known.
        public let project: URL?

        public init(tab: UUID, session: String, active: Bool, project: URL?) {
            self.tab = tab; self.session = session; self.active = active; self.project = project
        }
    }

    public init() {}

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
    public static let lingerForeground: TimeInterval = 20
    public static let lingerBackground: TimeInterval = 120

    private var folders: [String: URL] = [:]
    private var misses: [String: Date] = [:]
    private var progress: [String: Progress] = [:]

    /// The agents per session, and the paths whose changes call for another scan: the subagents
    /// folder and the files of agents still running, or, before the folder exists, the nearest
    /// folder on the way to it.
    public func scan(_ sessions: [Session]) -> (agents: [UUID: [SubAgent]], watch: Set<String>) {
        var result: [UUID: [SubAgent]] = [:]
        var watch: Set<String> = []
        for session in sessions {
            guard let folder = folder(for: session.session, in: session.project) else {
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
    private func folder(for session: String, in project: URL? = nil) -> URL? {
        if let folder = folders[session] { return folder }
        // Where the session's files are known to be: a remote session's copy isn't under ~/.claude.
        if let known = project?.appendingPathComponent(session).appendingPathComponent("subagents"),
           FileManager.default.fileExists(atPath: known.path) {
            folders[session] = known
            return known
        }
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
