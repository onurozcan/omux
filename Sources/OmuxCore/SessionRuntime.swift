import Foundation

/// Live, non-persisted state of one terminal tab.
public struct TabRuntime: Equatable {
    public var provider: SessionProvider?
    public var agentConnected = false
    /// When Codex's app-server took the session and its TUI command was typed.
    public var agentConnectedAt: Date?
    /// Codex's TUI has drawn its prompt (its first idle status line), so it takes input.
    public var tuiReady = false
    public var title = ""
    public var cwd: String?
    public var hasActivity = false
    /// When the session last did something: output, a status change, a bell.
    public var lastActivity: Date?
    public var needsAttention = false
    public var exited = false
    /// A program (e.g. claude) is running in the shell, as opposed to an idle prompt.
    public var busy = false
    public var statusState: StatusState?
    public var statusDetail: String?
    /// Why a blocked program waits: permission, question or auth.
    public var statusKind: String?
    /// OSC 7501 records other than the root, e.g. Claude Code's subagents.
    public var statusChildren: [StatusChild] = []

    public init(provider: SessionProvider? = nil, agentConnected: Bool = false, agentConnectedAt: Date? = nil, tuiReady: Bool = false,
                title: String = "", cwd: String? = nil, hasActivity: Bool = false, lastActivity: Date? = nil, needsAttention: Bool = false,
                exited: Bool = false, busy: Bool = false, statusState: StatusState? = nil, statusDetail: String? = nil,
                statusKind: String? = nil, statusChildren: [StatusChild] = []) {
        self.provider = provider; self.agentConnected = agentConnected; self.agentConnectedAt = agentConnectedAt; self.tuiReady = tuiReady
        self.title = title; self.cwd = cwd; self.hasActivity = hasActivity; self.lastActivity = lastActivity
        self.needsAttention = needsAttention; self.exited = exited; self.busy = busy; self.statusState = statusState
        self.statusDetail = statusDetail; self.statusKind = statusKind; self.statusChildren = statusChildren
    }

    public enum StatusState: String { case idle, working, done, blocked, error }

    /// The state without what changes many times a turn: the status wording, the subagent
    /// records, the window title and the time of the last sign of life. Two states equal in this
    /// look the same to everything but the session's own views.
    public var coarse: TabRuntime {
        var copy = self
        copy.statusDetail = nil; copy.statusChildren = []; copy.title = ""; copy.lastActivity = nil
        return copy
    }

    public struct StatusChild: Equatable {
        public let id: String
        public let state: StatusState?
        public let kind: String?
        public let message: String?
        public let title: String?
        public init(id: String, state: StatusState?, kind: String?, message: String?, title: String?) {
            self.id = id; self.state = state; self.kind = kind; self.message = message; self.title = title
        }
    }

    /// Claude Code is waiting on a tool permission, which Allow/Deny can answer. It reports plan
    /// approval and peer messages as "permission" too, but their first option isn't a plain
    /// yes; a tool prompt's message reads "approve <Tool>: …", or just "permission prompt" when
    /// it has no description for the call, as with some long Bash commands.
    public var awaitsPermission: Bool {
        guard statusState == .blocked, statusKind == "permission" else { return false }
        guard provider != .codex, let message = statusDetail else { return true }
        return message == "permission prompt" || message.range(of: #"^approve [\w-]+: "#, options: .regularExpression) != nil
    }

    public func statusLine(showFolder: Bool = true) -> String? {
        if let s = statusState {
            switch s {
            case .blocked: return (statusDetail ?? statusKind).map { "Needs you · \($0)" } ?? "Needs you"
            case .working: return statusDetail.map { "Working · \($0)" } ?? "Working…"
            case .done: return "Done"
            case .error: return statusDetail.map { "Error · \($0)" } ?? "Error"
            case .idle: break
            }
        }
        if exited { return "Stopped" }
        if !title.isEmpty { return title }
        if showFolder, let cwd { return cwd.tildeAbbreviated }
        return nil
    }
}
