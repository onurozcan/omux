import AppKit
import SwiftUI
import UserNotifications

/// Where the login shell finds a command, or nil. Looked up off the main thread.
enum Tools {
    static func path(of command: String) async -> String? {
        await Task.detached {
            let out = Git.login("command -v \(command)", in: NSHomeDirectory()).out.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.hasPrefix("/") ? out : nil
        }.value
    }
}

/// First-launch checks: the agents, notifications, usage limits, and a first project.
/// Also under Help › Welcome to omux.
struct WelcomeSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var usage = UsageMonitor()
    @ObservedObject private var codex = CodexManager.shared
    @State private var claudePath: String??
    @State private var codexPath: String??
    @State private var notifications: UNAuthorizationStatus?
    @State private var checkedUsage = false
    @AppStorage(Prefs.keepAwake) private var keepAwakeOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to omux").font(.title2.bold())
                Text("A terminal for running many Claude Code and Codex sessions side by side. A few checks before you start.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    agents
                    notificationsSection
                    usageSection
                    keepAwakeSection
                    projects
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Open this again from Help › Welcome to omux.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 600)
        .task {
            UserDefaults.standard.set(true, forKey: Prefs.welcomed)
            async let claude = Tools.path(of: "claude")
            async let codex = Tools.path(of: "codex")
            claudePath = .some(await claude)
            codexPath = .some(await codex)
            notifications = await Notifier.shared.authorizationStatus()
        }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
    }

    private var agents: some View {
        section("Agents", "terminal") {
            toolRow("Claude Code", command: "claude", path: claudePath,
                    missing: "Not found. Install it with `npm install -g @anthropic-ai/claude-code`, or see claude.com/claude-code. Plain shell sessions work without it.")
            toolRow("Codex", command: "codex", path: codexPath,
                    missing: "Not found. Optional: `npm install -g @openai/codex` to run Codex sessions too.")
        }
    }

    private func toolRow(_ name: String, command: String, path: String??, missing: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch path {
            case .none: ProgressView().controlSize(.small).frame(width: 16)
            case .some(.some): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(nil): Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                switch path {
                case .some(.some(let found)): Text(found).font(.caption.monospaced()).foregroundStyle(.secondary)
                case .some(nil): Text(missing).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .none: Text("Looking…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notificationsSection: some View {
        section("Notifications", "bell") {
            Text("omux notifies you when a session you aren't looking at needs you, with a sound. Sound only, and which sound, are in Settings › Notifications.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                switch notifications {
                case .authorized?, .provisional?:
                    Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied?:
                    Label("Turned off for omux", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                case .notDetermined?:
                    Button("Enable notifications") {
                        Task { notifications = await Notifier.shared.requestAuthorization() }
                    }
                default:
                    ProgressView().controlSize(.small)
                }
                Button("Play the sound") { Notifier.shared.playSound() }
            }
            .controlSize(.small)
        }
    }

    private var usageSection: some View {
        section("Usage limits", "gauge") {
            Text("The sidebar shows the selected agent's plan limits. Claude's need a Claude.ai plan login in Claude Code (run claude, then /login), and macOS asks once to allow reading that login from the Keychain: click Allow. Codex's come from its own login (codex login).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(checkedUsage ? "Check again" : "Check now") {
                checkedUsage = true
                usage.refresh()
                if case .some(.some) = codexPath { Task { await codex.refreshUsage() } }
            }
            .controlSize(.small)
            if checkedUsage {
                usageRow("Claude", limits: usage.limits, error: usage.detail ?? usage.error)
                if case .some(.some) = codexPath {
                    usageRow("Codex", limits: codex.limits, error: codex.usageError)
                }
            }
        }
    }

    private func usageRow(_ name: String, limits: [UsageMonitor.Limit], error: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(name).frame(width: 52, alignment: .leading)
            if !limits.isEmpty {
                Label(limits.map { "\($0.label) \($0.percent)%" }.joined(separator: "  "), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
    }

    private var keepAwakeSection: some View {
        section("Keep awake", "cup.and.saucer") {
            Text("omux can keep your Mac awake while agents work, even with the lid closed and the Mac in your bag. It stops on its own if the Mac gets hot, the battery falls to 10%, or the time limit passes. Turning it on asks for administrator approval once.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if keepAwakeOn {
                KeepAwakeHelperStatus()
            } else {
                Button("Turn on") { KeepAwake.shared.setEnabled(true) }
                    .controlSize(.small)
            }
        }
    }

    private var projects: some View {
        section("First project", "folder") {
            Text("A project is a folder with sessions under it. Open one now, or pick up a conversation Claude Code already has.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open a folder…") {
                    dismiss()
                    DispatchQueue.main.async { store.openFolderPanel() }
                }
                Button("Recent conversations…") {
                    dismiss()
                    DispatchQueue.main.async { store.showRecentSessions = true }
                }
            }
            .controlSize(.small)
        }
    }
}
