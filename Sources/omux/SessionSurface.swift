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

    func makeNSView(context: Context) -> BreathingDotView { BreathingDotView() }

    func updateNSView(_ view: BreathingDotView, context: Context) {
        view.apply(color: color, pulsing: pulsing)
    }
}

final class BreathingDotView: NSView {
    private let dot = CALayer()
    private var color: Color = .clear
    private var pulsing = false
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

    func apply(color: Color, pulsing: Bool) {
        if color != self.color {
            self.color = color
            fill()
        }
        if pulsing != self.pulsing {
            self.pulsing = pulsing
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
        animation.toValue = 0.35
        animation.duration = 0.9
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

@MainActor
enum SessionViewMode {
    /// Whether the transcript view applies to a session: the project's own choice, else Settings'.
    /// Every session, shells included; the compose box turns a shell into an agent session on the first message.
    static func showsTranscript(_ tabID: UUID, store: Store) -> Bool {
        guard store.tab(tabID) != nil else { return false }
        if let own = store.group(containing: tabID)?.sessionView, !own.isEmpty { return own == "transcript" }
        return UserDefaults.standard.string(forKey: Prefs.sessionView) == "transcript"
    }
}

/// A session in the main panel: its terminal, or the transcript over the terminal. The terminal
/// stays hosted at full size underneath, so the program keeps its screen and the panel reads it;
/// it is just not visible.
struct SessionSurface<Terminal: View>: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var peek = TerminalPeek.shared
    @AppStorage(Prefs.sessionView) private var sessionView = "terminal"
    let tabID: UUID
    let theme: Theme
    /// Which page this surface draws into: "single" for the one-session view, the pane's own for a pane.
    var slot: String = "single"
    var hooks: DropHooks? = nil
    @ViewBuilder let terminal: () -> Terminal

    /// The same decision as SessionViewMode, read through the view's own setting so it follows changes.
    private var mode: Bool {
        guard store.tab(tabID) != nil else { return false }
        if let own = store.group(containing: tabID)?.sessionView, !own.isEmpty { return own == "transcript" }
        return sessionView == "transcript"
    }

    var body: some View {
        let mode = mode
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
            if peeking {
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
