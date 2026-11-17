import SwiftUI

// The main panel's session surface: the terminal, or Settings' transcript view over it, with
// the terminal still hosted underneath. Also the status dot every session row shares.

/// Whether the terminal under a session surface should draw: false while a transcript covers it.
private struct TerminalVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var terminalVisible: Bool {
        get { self[TerminalVisibleKey.self] }
        set { self[TerminalVisibleKey.self] = newValue }
    }
}

/// A session's status dot; it breathes while the agent is working.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 8

    var body: some View {
        BreathingDot(color: color, pulsing: pulsing)
            .frame(width: size, height: size)
    }
}

/// A round dot whose breathing is a Core Animation layer animation. The render server plays
/// it, so the main thread does nothing per frame. A SwiftUI `repeatForever` animation here
/// re-rendered the whole hosting view at the display's refresh rate for as long as any agent
/// worked, which cost omux a fifth of a core.
struct BreathingDot: NSViewRepresentable {
    let color: Color
    let pulsing: Bool
    /// A slow blink, down to nearly nothing and back: for a surface that waits for an answer.
    var slow = false

    func makeNSView(context: Context) -> BreathingDotView { BreathingDotView() }

    func updateNSView(_ view: BreathingDotView, context: Context) {
        view.apply(color: color, pulsing: pulsing, slow: slow)
    }
}

final class BreathingDotView: NSView {
    private let dot = CALayer()
    private var color: Color = .clear
    private var pulsing = false
    private var slow = false
    private static let animationKey = "breathe"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    func apply(color: Color, pulsing: Bool, slow: Bool = false) {
        if color != self.color {
            self.color = color
            fill()
        }
        if pulsing != self.pulsing || slow != self.slow {
            self.pulsing = pulsing
            self.slow = slow
            dot.removeAnimation(forKey: Self.animationKey)
            breathe()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fill()
    }

    /// Core Animation drops a layer's animations when the layer leaves its window, so a dot
    /// that is scrolled or switched back into view starts breathing again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { breathe() }
    }

    private func fill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor(color).cgColor
        }
        CATransaction.commit()
    }

    private func breathe() {
        guard pulsing else {
            dot.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard dot.animation(forKey: Self.animationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = slow ? 0.12 : 0.35
        animation.duration = slow ? 1.5 : 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(animation, forKey: Self.animationKey)
    }
}

/// Sessions whose terminal is shown over the transcript for a moment: a dialog a slash command
/// opened, which goes away when the conversation moves on, or a peek the user asked for, which stays.
@MainActor
final class TerminalPeek: ObservableObject {
    static let shared = TerminalPeek()
    @Published private(set) var tabs: Set<UUID> = []
    private var automatic: Set<UUID> = []

    func show(_ id: UUID, store: Store, automatic: Bool = false) {
        tabs.insert(id)
        if automatic { self.automatic.insert(id) } else { self.automatic.remove(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let term = store.terminal(for: id) { term.window?.makeFirstResponder(term) }
        }
    }

    func hide(_ id: UUID) {
        tabs.remove(id)
        automatic.remove(id)
    }

    /// Ends a peek a dialog opened; one the user opened stays until they close it.
    func hideAutomatic(_ id: UUID) {
        guard automatic.contains(id) else { return }
        hide(id)
    }
}

/// Sessions a stopped-session preview is starting from its compose box. The preview stays up
/// until the prompt is typed into the agent: the transcript's compose box is what waits for the
/// agent to be ready, so it can't go away the moment the agent starts.
@MainActor
final class StoppedPreview: ObservableObject {
    static let shared = StoppedPreview()
    @Published private(set) var holding: Set<UUID> = []

    func hold(_ id: UUID) { holding.insert(id) }
    func release(_ id: UUID) { holding.remove(id) }
}

@MainActor
enum SessionViewMode {
    /// Whether the transcript view applies to a session: the project's own choice, else Settings',
    /// else the preview of a stopped agent session.
    /// Every session, shells included; the compose box turns a shell into an agent session on the first message.
    static func showsTranscript(_ tabID: UUID, store: Store) -> Bool {
        guard store.tab(tabID) != nil else { return false }
        if chosen(tabID, store: store, setting: UserDefaults.standard.string(forKey: Prefs.sessionView)) { return true }
        let enabled = UserDefaults.standard.object(forKey: Prefs.previewStopped) as? Bool ?? true
        return previewsStopped(tabID, store: store, runtime: store.runtime[tabID], enabled: enabled)
    }

    /// The transcript view as chosen: the project's own choice, else Settings'.
    static func chosen(_ tabID: UUID, store: Store, setting: String?) -> Bool {
        if let own = store.group(containing: tabID)?.sessionView, !own.isEmpty { return own == "transcript" }
        return setting == "transcript"
    }

    /// In the terminal view, a Claude Code or Codex session that isn't running shows its
    /// conversation instead of an empty shell: you can read where it left off without starting
    /// it, and a message sent from the box below starts it the way ▶ does. Once the agent runs,
    /// the terminal is back.
    static func previewsStopped(_ tabID: UUID, store: Store, runtime: TabRuntime?, enabled: Bool) -> Bool {
        guard enabled, let tab = store.tab(tabID), store.group(containing: tabID)?.isRemote != true else { return false }
        let provider = store.transcriptProvider(of: tab)
        guard provider == .claude || provider == .codex else { return false }
        if StoppedPreview.shared.holding.contains(tabID) { return true }
        guard let rt = runtime, !rt.exited else { return true }
        return !rt.busy && !TranscriptPanel.takesInput(rt)
    }
}

/// A session in the main panel: its terminal, or the transcript over the terminal. The terminal
/// stays hosted at full size underneath, so the program keeps its screen and the panel reads it;
/// it is just not visible.
struct SessionSurface<Terminal: View>: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var peek = TerminalPeek.shared
    @ObservedObject private var stoppedPreview = StoppedPreview.shared
    @AppStorage(Prefs.sessionView) private var sessionView = "terminal"
    @AppStorage(Prefs.previewStopped) private var previewStopped = true
    let tabID: UUID
    let theme: Theme
    /// Which page this surface draws into: "single" for the one-session view, the pane's own for a pane.
    var slot: String = "single"
    var hooks: DropHooks? = nil
    @ViewBuilder let terminal: () -> Terminal

    /// The same decision as SessionViewMode, read through the view's own settings and the
    /// session's runtime so it follows changes: a stopped session's preview gives way to the
    /// terminal as soon as its agent runs.
    private func mode(_ runtime: TabRuntime) -> Bool {
        guard store.tab(tabID) != nil else { return false }
        if SessionViewMode.chosen(tabID, store: store, setting: sessionView) { return true }
        return SessionViewMode.previewsStopped(tabID, store: store, runtime: runtime, enabled: previewStopped)
    }

    var body: some View {
        WithRuntime(tabID) { runtime in surface(mode: mode(runtime)) }
    }

    @ViewBuilder private func surface(mode: Bool) -> some View {
        let peeking = mode && peek.tabs.contains(tabID)
        let transcript = mode && !peeking
        ZStack(alignment: .topTrailing) {
            terminal()
                .environment(\.terminalVisible, !transcript)
                .opacity(transcript ? 0 : 1)
                .allowsHitTesting(!transcript)
                .accessibilityHidden(transcript)
            if mode, let tab = store.tab(tabID) {
                TranscriptPanel(tab: tab, provider: store.transcriptProvider(of: tab), theme: theme, compact: true, slot: slot, hooks: hooks,
                                claudeFile: { [store] in store.claudeTranscriptURL(for: tabID) },
                                claudeFolder: { [store] in store.claudeProjectFolderURL(for: tabID) },
                                codexThread: { [store] in store.tab(tabID)?.codexThreadID })
                    .id(tabID)
                    .opacity(peeking ? 0 : 1)
                    .allowsHitTesting(!peeking)
                    .accessibilityHidden(peeking)
            }
            // The one session the window shows goes back with the eye in the header; a pane has
            // no header of its own showing while its terminal is up, so it keeps this button.
            if peeking, slot != "single" {
                Button { peek.hide(tabID) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.bubble").imageScale(.small)
                        Text("Back to transcript")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Back to the conversation (⌥⌘P)")
            }
        }
    }
}
