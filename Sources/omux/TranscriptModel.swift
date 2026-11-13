import Foundation

// The Transcript view's data: a session's conversation as blocks, read from Claude Code's
// transcript file or Codex's thread, kept per session while the app runs. TranscriptPanel.swift draws it.

/// The models, one per session, kept while the app runs so switching sessions doesn't reread
/// and reparse the transcript. A model is paused while no panel shows it.
@MainActor
final class TranscriptModels {
    static let shared = TranscriptModels()
    private var models: [UUID: SessionTranscript] = [:]

    func model(for tab: TabItem, provider: SessionProvider, claudeFile: @escaping () -> URL?, claudeFolder: @escaping () -> URL? = { nil },
               codexThread: @escaping () -> String?) -> SessionTranscript {
        if let existing = models[tab.id] {
            existing.switchTo(provider)
            return existing
        }
        let model = SessionTranscript(tab: tab, provider: provider, claudeFile: claudeFile, claudeFolder: claudeFolder, codexThread: codexThread)
        models[tab.id] = model
        return model
    }

    /// Drops the models of sessions that no longer exist, and the content of ones nothing has
    /// shown for a while, so a workspace of many sessions doesn't hold every conversation.
    func prune(keeping ids: Set<UUID>) {
        for id in models.keys where !ids.contains(id) { models[id]?.pause(); models[id] = nil }
        for model in models.values {
            if let since = model.pausedAt, Date().timeIntervalSince(since) > Self.unloadAfter, model.memoryBytes > Self.unloadOver { model.unload() }
        }
    }
    private static let unloadAfter: TimeInterval = 10 * 60
    private static let unloadOver = 1 << 20
}

extension SessionTranscript {
    /// A session's transcript, with Codex's threads coming from the app's connection to it.
    convenience init(tab: TabItem, provider: SessionProvider, claudeFile: @escaping () -> URL?, claudeFolder: @escaping () -> URL? = { nil },
                     codexThread: @escaping () -> String?) {
        self.init(tabID: tab.id, provider: provider, claudeFile: claudeFile, claudeFolder: claudeFolder, codexThread: codexThread, codex: CodexManager.shared)
    }
}

extension CodexManager: CodexThreads {}
