import Foundation

/// An `omux://reveal` link, which brings one session forward. Other apps that watch agents
/// (notifications, menu bar monitors) use it to open the session an agent runs in:
///
///     omux://reveal?tab=<session UUID>             // OMUX_TAB_ID
///     omux://reveal?claude-session=<session id>    // Claude Code's session_id
///     omux://reveal?codex-thread=<thread id>       // Codex's thread id
///
/// A link only selects a session. It never starts, types into or changes one.
enum RevealLink: Equatable {
    case tab(UUID)
    case claudeSession(UUID)
    case codexThread(String)

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "omux", url.host?.lowercased() == "reveal",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let id = value("tab").flatMap(UUID.init(uuidString:)) {
            self = .tab(id)
        } else if let id = value("claude-session").flatMap(UUID.init(uuidString:)) {
            self = .claudeSession(id)
        } else if let thread = value("codex-thread") {
            self = .codexThread(thread)
        } else {
            return nil
        }
    }
}

extension Store {
    /// The session a reveal link points at, if it's still open.
    func tabID(for link: RevealLink) -> UUID? {
        allTabs.first { entry in
            switch link {
            case .tab(let id): entry.tab.id == id
            case .claudeSession(let id): entry.tab.claudeSessionID == id && provider(of: entry.tab) == .claude
            case .codexThread(let thread): entry.tab.codexThreadID == thread
            }
        }?.tab.id
    }
}
