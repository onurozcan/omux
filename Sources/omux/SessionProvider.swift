import Foundation

enum SessionProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor, shell, custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor CLI"
        case .shell: return "Plain shell"
        case .custom: return "Custom command"
        }
    }

    /// What the agent is called in the interface, for buttons and status lines.
    var agentName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .shell, .custom: return "the session"
        }
    }

    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor-agent"
        case .shell, .custom: return ""
        }
    }

    /// Existing custom commands keep their exact text. Only the standard Codex
    /// command opts into managed Codex sessions; wrappers remain ordinary commands.
    static func infer(command: String?) -> SessionProvider {
        let raw = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .shell }
        if raw == "codex" { return .codex }
        let match = [SessionProvider.claude, .cursor].first {
            raw == $0.command || raw.hasPrefix($0.command + " ")
        }
        return match ?? .custom
    }

    /// Cursor can't be told which id to use, so there is nothing to pin to until omux has
    /// asked it for a chat.
    static func cursorCommand(_ raw: String, chatID: String?) -> String {
        guard let chatID else { return raw }
        return pinned(raw, to: "cursor-agent", conversation: "--resume \(chatID)",
                      alsoSkip: ["--continue", "ls", "resume", "create-chat"])
    }

    /// `--session-id` opens a new conversation under an id we pick, `--resume` reopens it.
    static func claudeCommand(_ raw: String, sessionID: UUID, conversationExists: Bool) -> String {
        let session = sessionID.uuidString.lowercased()
        let conversation = conversationExists ? "--resume \(session)" : "--session-id \(session)"
        return pinned(raw, to: "claude", conversation: conversation, alsoSkip: ["--continue", "-c"])
    }

    /// Puts the conversation flag straight after the executable, so the session reopens its
    /// own conversation. A command that already picks one is left exactly as the user wrote it.
    private static func pinned(_ raw: String, to executable: String,
                               conversation: String, alsoSkip: Set<String>) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == executable else { return raw }
        let rest = parts.count > 1 ? parts[1] : ""
        let words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        let flags = alsoSkip.union(["--resume", "-r", "--session-id"])
        if words.contains(where: { flags.contains($0) || $0.hasPrefix("--resume=") || $0.hasPrefix("--session-id=") }) { return raw }
        return [executable, conversation, rest].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
