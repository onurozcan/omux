import Foundation

/// What Codex's app-server says about a thread while a transcript follows it.
public enum CodexTranscriptEvent {
    case item(id: String, type: String, completed: Bool), turn(completed: Bool), delta(item: String, text: String)
}

/// Where a transcript gets a Codex thread from: the app's connection to Codex's app-server.
@MainActor
public protocol CodexThreads: AnyObject {
    /// Events of the session's thread go to `handler`; nil stops them.
    func listen(_ tabID: UUID, _ handler: ((CodexTranscriptEvent) -> Void)?)
    /// The thread's items, oldest first, as the app-server returns them.
    func transcriptItems(threadID: String, tabID: UUID) async throws -> [[String: Any]]
}
