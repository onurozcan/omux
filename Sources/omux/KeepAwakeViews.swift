import SwiftUI

/// The omux ring: the app icon's neon "o", drawn at any size.
struct AwakeRing: View {
    static let gradient = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x5EEAD4)),
                                                  Color(nsColor: NSColor(hex: 0x22D3EE)),
                                                  Color(nsColor: NSColor(hex: 0xA78BFA))],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let glow = Color(nsColor: NSColor(hex: 0x22D3EE))

    var size: CGFloat
    /// How much of the ring is drawn, clockwise from the top.
    var progress: CGFloat = 1
    /// 0…1, the soft glow around it.
    var glow: CGFloat = 0

    var body: some View {
        let width = size * 0.17
        ZStack {
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Self.glow, style: StrokeStyle(lineWidth: width * 1.4, lineCap: .round))
                .blur(radius: size * 0.08)
                .opacity(0.6 * glow)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Self.gradient, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        .rotationEffect(.degrees(-90))
        .padding(width / 2)
        .frame(width: size, height: size)
    }
}

/// Next to the usage limits while Keep Awake is on: a small cup that glows while the Mac is kept
/// awake and is grey otherwise (turned off, or no agent working). Click for a popover with what's
/// going on, Screen Off and Turn Off or Turn On.
struct AwakeIndicator: View {
    @ObservedObject private var awake = KeepAwake.shared
    @AppStorage(Prefs.keepAwake) private var enabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing = false
    @State private var hovered = false

    var body: some View {
        if enabled {
            let active = awake.isHolding
            let needsApproval = awake.helperStatus != .enabled
            Button { awake.refreshStatus(); showing.toggle() } label: {
                Image(systemName: active ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? AnyShapeStyle(AwakeRing.gradient) : AnyShapeStyle(.tertiary))
                    .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion && !hovered)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(hovered || active ? 1 : 0.8)
                    .frame(width: 18, height: 16)
                    .overlay(alignment: .topTrailing) {
                        if needsApproval {
                            Circle().fill(.orange).frame(width: 5, height: 5).offset(x: -1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(needsApproval ? AwakePopover.approvalText(awake.helperStatus)
                  : active ? "Keeping the Mac awake" : awake.paused ? "Keep Awake is off for now" : "Keep Awake starts when an agent works")
            .popover(isPresented: $showing, arrowEdge: .top) {
                AwakePopover { showing = false }
            }
            .contextMenu {
                Button("Screen Off") { ScreenOff.shared.start() }
                if active {
                    Button("Turn Off Keep Awake") { awake.endNow() }
                } else if awake.paused {
                    Button("Turn On Keep Awake") { awake.resume() }
                }
            }
            .accessibilityLabel(active ? "Keeping the Mac awake" : "Keep Awake, off for now")
            .animation(.easeInOut(duration: 0.25), value: active)
        }
    }

    /// "2h 41m", or "41m" under an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// What the indicator's click shows.
struct AwakePopover: View {
    @ObservedObject private var awake = KeepAwake.shared
    let close: () -> Void

    var body: some View {
        let active = awake.isHolding
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: active ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .foregroundStyle(active ? AnyShapeStyle(AwakeRing.gradient) : AnyShapeStyle(.secondary))
                Text(active ? "Keeping your Mac awake" : awake.paused ? "Keep Awake is off for now" : "Keep Awake is ready")
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                if active {
                    Text(agents)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in Text(limitText) }
                } else if awake.paused {
                    Text("Your Mac can sleep. Turn it on to keep it awake while agents work.")
                } else {
                    Text("It starts when an agent works.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if awake.helperStatus != .enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Label(Self.approvalText(awake.helperStatus), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    switch awake.helperStatus {
                    case .requiresApproval:
                        Button("Open Login Items Settings") { close(); awake.openLoginItems() }
                    case .notRegistered:
                        Button("Set Up") { awake.setEnabled(true) }
                    default:
                        EmptyView()
                    }
                }
            } else if active, !awake.helperHolds {
                Label("The lid can't close yet: the helper isn't holding sleep off.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Screen Off") { close(); ScreenOff.shared.start() }
                Spacer()
                if active {
                    Button("Turn Off") { awake.endNow() }
                        .keyboardShortcut(.defaultAction)
                } else if awake.paused {
                    Button("Turn On") { awake.resume() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .animation(.easeInOut(duration: 0.2), value: active)
    }

    /// Why the lid can't close yet, for the cup's tooltip and the popover.
    static func approvalText(_ status: HelperStatus) -> String {
        switch status {
        case .requiresApproval:
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "omux"
            return "Needs your approval to keep the Mac awake with the lid closed: turn on \(name) in System Settings › Login Items."
        case .notRegistered:
            return "The helper that keeps the Mac awake with the lid closed isn't set up."
        case .unavailable(let reason):
            return "The lid can't close yet: \(reason)"
        case .enabled:
            return ""
        }
    }

    private var agents: String {
        switch awake.activeAgents {
        case 0: return "Agents finished. Staying awake so you can continue from your phone."
        case 1: return "1 agent working."
        default: return "\(awake.activeAgents) agents working."
        }
    }

    private var limitText: String {
        if let remaining = awake.remaining { return "Lets the Mac sleep in \(AwakeIndicator.duration(remaining)) unless you're back." }
        return "The \(AwakeIndicator.duration(awake.limit)) limit starts when the screen goes dark."
    }
}

/// Settings › Keep Awake.
struct KeepAwakeSettings: View {
    @ObservedObject private var awake = KeepAwake.shared
    @AppStorage(Prefs.keepAwake) private var enabled = false
    @AppStorage(Prefs.keepAwakeLimit) private var limit = KeepAwake.defaultLimit
    @AppStorage(Prefs.keepAwakeReleaseWhenDone) private var releaseWhenDone = false

    var body: some View {
        Section("Keep Awake") {
            Toggle("Keep Mac awake while agents work", isOn: Binding(get: { enabled }, set: { awake.setEnabled($0) }))
            Text("Even with the lid closed. Turning it on asks for administrator approval once, in System Settings › Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled { KeepAwakeHelperStatus() }
            Picker("Stop after the screen is dark for", selection: $limit) {
                Text("1 hour").tag(3600.0)
                Text("2 hours").tag(7200.0)
                Text("3 hours").tag(10800.0)
                Text("6 hours").tag(21600.0)
                Text("12 hours").tag(43200.0)
            }
            .disabled(!enabled)
            Toggle("Let Mac sleep when all agents finish", isOn: $releaseWhenDone)
                .disabled(!enabled)
            Text("While this is off, your Mac stays awake after agents finish, so you can keep going with your Claude Code sessions from your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The time limit only counts while nobody is at the screen: lid closed, Screen Off or display asleep. It also stops on its own if the Mac gets hot or the battery falls to 10%. Keep the Mac somewhere it can breathe.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Whether the helper that keeps the Mac awake with the lid closed is running, and how to fix it.
struct KeepAwakeHelperStatus: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        HStack(spacing: 10) {
            switch awake.helperStatus {
            case .enabled:
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .requiresApproval:
                Label("Waiting for approval", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                Button("Open Login Items Settings") { awake.openLoginItems() }
            case .notRegistered:
                Label("Not set up", systemImage: "xmark.circle").foregroundStyle(.secondary)
                Button("Set Up") { awake.setEnabled(true) }
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .controlSize(.small)
    }
}
