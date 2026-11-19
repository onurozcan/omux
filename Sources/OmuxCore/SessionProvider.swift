import Foundation

public enum SessionProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, shell, custom

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Plain shell"
        case .custom: return "Custom command"
        }
    }

    public var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .shell, .custom: return ""
        }
    }

    /// Whether omux may start this agent on its own in `directory`. An agent started in the
    /// home folder takes all of it as its project and reads Downloads, Documents, Pictures and
    /// Music, so macOS asks the user, in omux's name, for access to each of them.
    public func startsAutomatically(in directory: String, home: String = NSHomeDirectory()) -> Bool {
        guard self == .claude || self == .codex else { return true }
        func normalized(_ path: String) -> String { ((path as NSString).expandingTildeInPath as NSString).standardizingPath }
        return normalized(directory) != normalized(home)
    }

    /// Existing custom commands keep their exact text. Only the standard Codex
    /// command opts into managed Codex sessions; wrappers remain ordinary commands.
    public static func infer(command: String?) -> SessionProvider {
        let raw = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .shell }
        if raw == "codex" { return .codex }
        if raw == "claude" || raw.hasPrefix("claude ") { return .claude }
        return .custom
    }

    public static func claudeCommand(_ raw: String, sessionID: UUID, conversationExists: Bool, continueLatest: Bool = false) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == "claude" else { return raw }
        let rest = parts.count > 1 ? parts[1] : ""
        let words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        let flags: Set<String> = ["--resume", "-r", "--continue", "-c", "--session-id"]
        if words.contains(where: { flags.contains($0) || $0.hasPrefix("--resume=") || $0.hasPrefix("--session-id=") }) { return raw }
        let session = sessionID.uuidString.lowercased()
        let flag = conversationExists ? "--resume \(session)" : (continueLatest ? "--continue" : "--session-id \(session)")
        return ["claude", flag, rest].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
