import AppKit
import SwiftUI

@main
struct OmuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    init() { Prefs.importReleaseSettingsIfBeta() }

    var body: some Scene {
        Window(Persistence.isBeta ? "omux Beta" : "omux", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(store: store) }

        Settings { SettingsView() }
    }
}

enum Prefs {
    static let confirmQuit = "confirmQuit"
    static let showFolderPath = "showFolderPath"
    static let usageInterval = "usageInterval"
    static let theme = "theme"
    static let autoResume = "autoResume"
    static let showFiles = "showFiles"
    static let filesByDate = "filesByDate"
    static let filesBrowserCollapsed = "filesBrowserCollapsed"
    static let previewWrapLines = "previewWrapLines"
    static let panelTab = "panelTab"
    static let fontFamily = "fontFamily"
    static let fontSize = "fontSize"
    static let notifyNeedsYou = "notifyNeedsYou"
    static let notifyDone = "notifyDone"
    static let notifyPrograms = "notifyPrograms"
    /// "banner" (default) or "sound".
    static let notifyStyle = "notifyStyle"
    /// A macOS alert sound name, or "Default".
    static let notifySound = "notifySound"
    static let welcomed = "welcomed"
    /// Session names follow Claude Code's /rename and its auto-generated title. Off by default.
    static let inheritClaudeSessionName = "inheritClaudeSessionName"

    static let all = [confirmQuit, showFolderPath, usageInterval, theme, autoResume, showFiles, filesByDate,
                      filesBrowserCollapsed, previewWrapLines, panelTab, fontFamily, fontSize,
                      notifyNeedsYou, notifyDone, notifyPrograms, inheritClaudeSessionName]

    /// A beta build (./build.sh --beta) starts out with the release app's settings, such as
    /// the theme and font, instead of the defaults. Only on its first launch.
    static func importReleaseSettingsIfBeta() {
        let flag = "importedReleaseSettings"
        guard Persistence.isBeta, !UserDefaults.standard.bool(forKey: flag),
              let release = UserDefaults(suiteName: "net.pf1.omux") else { return }
        for key in all {
            if let value = release.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.confirmQuit) private var confirmQuit = true
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0
    @AppStorage(Prefs.theme) private var theme = Theme.dark.rawValue
    @AppStorage(Prefs.fontFamily) private var fontFamily = ""
    @AppStorage(Prefs.fontSize) private var fontSize = Fonts.defaultSize
    @AppStorage(Prefs.autoResume) private var autoResume = false
    @AppStorage(Prefs.notifyStyle) private var notifyStyle = "banner"
    @AppStorage(Prefs.notifySound) private var notifySound = "Default"
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true
    @AppStorage(Prefs.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDone) private var notifyDone = false
    @AppStorage(Prefs.notifyPrograms) private var notifyPrograms = true
    @AppStorage(Prefs.inheritClaudeSessionName) private var inheritClaudeName = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Font", selection: $fontFamily) {
                    Text("System Mono").tag("")
                    ForEach(Fonts.monospaceFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: Fonts.sizes)
            }
            Section("Sidebar") {
                Toggle("Show folder path under session name", isOn: $showFolderPath)
                Picker("Check Claude limits every", selection: $usageInterval) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("30 minutes").tag(1800.0)
                    Text("Hour").tag(3600.0)
                }
            }
            Section("Files Panel") {
                Toggle("Wrap long lines in file preview", isOn: $wrapLines)
            }
            Section("Sessions") {
                Toggle("Auto-resume agent sessions at launch", isOn: $autoResume)
                Text("Off: restored sessions stay stopped until you press ▶. Clicking one only opens its shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Confirm before quitting while sessions are running", isOn: $confirmQuit)
                Text("Quitting stops every session. Saved Claude Code and Codex conversations can be continued on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Claude Session Name Inheritance", isOn: $inheritClaudeName)
                Text("Session names follow Claude Code's /rename and, until you rename a session yourself, its auto-generated title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("When a session needs you", isOn: $notifyNeedsYou)
                Toggle("When a session finishes", isOn: $notifyDone)
                Toggle("When a program in a session sends one", isOn: $notifyPrograms)
                Text("Only for sessions you aren't looking at. Programs send them with OSC 9 or OSC 777: set Claude Code's notification channel to ghostty (/config) to get its plugins' notifications too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Style", selection: $notifyStyle) {
                    Text("Banner and sound").tag("banner")
                    Text("Sound only").tag("sound")
                }
                HStack {
                    Picker("Sound", selection: $notifySound) {
                        ForEach(Notifier.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Play") { Notifier.shared.playSound() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Keeps the close, minimize and zoom buttons visible while the toolbar is hidden. Hiding the
/// window toolbar removes them on some macOS versions; keeping the toolbar instead leaves an
/// invisible strip that pushes the content down and swallows clicks on the sidebar's buttons.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.theme) private var themeName = Theme.dark.rawValue
    @AppStorage(Prefs.fontFamily) private var fontFamily = ""
    @AppStorage(Prefs.fontSize) private var fontSize = Fonts.defaultSize
    @AppStorage(Prefs.showFiles) private var showFiles = false

    private var theme: Theme { Theme(rawValue: themeName) ?? .dark }

    /// Changes follow the selected session and its folder.
    private var changesKey: String {
        let tab = store.selectedTab
        return "\(tab?.id.uuidString ?? "")|\(tab?.directory ?? "")|\(tab?.worktree?.branch ?? "")"
    }

    /// Folder the file panel shows: the selected session's folder, else its project's.
    private var projectRoot: URL {
        let tab = store.selectedTab
        let group = store.selectedGroup
        let path = tab?.directory ?? group?.directory ?? NSHomeDirectory()
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(theme: theme)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    SessionHeader(theme: theme, showFiles: $showFiles)
                    // Over the terminal, so a notice doesn't resize the session.
                    ZStack(alignment: .top) {
                        if let id = store.selectedTabID, let term = store.terminal(for: id) {
                            TerminalHost(termView: term, theme: theme)
                        } else {
                            ContentUnavailableView("No session", systemImage: "terminal", description: Text("Press ⌘T to start one."))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: theme.background))
                        }
                        NoticeStack(theme: theme)
                    }
                }
                .frame(minWidth: 360)
                .ignoresSafeArea(.container, edges: .top)
                if showFiles {
                    RightPanel(root: projectRoot, theme: theme)
                        .frame(minWidth: 260, idealWidth: 380, maxWidth: 900)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
            // Each pane ignores the title bar inset itself, so the session header and the panel's
            // tabs sit level with the sidebar's buttons. On the split view alone it doesn't reach them.
        }
        .toolbar(.hidden, for: .windowToolbar)
        .background(WindowChrome())
        .preferredColorScheme(theme.colorScheme)
        .background(Color(nsColor: theme.chrome))
        .onChange(of: themeName) { _, _ in store.applyAppearance() }
        .onChange(of: fontFamily) { _, _ in store.applyAppearance() }
        .onChange(of: fontSize) { _, _ in store.applyAppearance() }
        .onChange(of: store.previewRequest) { _, path in if path != nil { store.showPanel(.files) } }
        .onChange(of: changesKey, initial: true) { _, _ in
            let tab = store.selectedTab
            Changes.shared.track(tabID: tab?.id, dir: tab.flatMap(store.directory(of:)), worktree: tab?.worktree)
        }
        .sheet(item: $store.newWorktreeGroupID) { WorktreeSheet(groupID: $0).environmentObject(store) }
        .sheet(isPresented: $store.showQuickSwitcher) { QuickSwitcher().environmentObject(store) }
        .sheet(isPresented: $store.showRecentSessions) { RecentSessionsSheet().environmentObject(store) }
        .sheet(isPresented: $store.showWelcome) { WelcomeSheet().environmentObject(store) }
        .sheet(item: $store.editingTabID) { TabEditSheet(tabID: $0).environmentObject(store) }
        .sheet(item: $store.editingGroupID) { GroupEditSheet(groupID: $0).environmentObject(store) }
        .onAppear {
            AppDelegate.openWindow = openWindow
            ClaudeTitleMonitor.shared.start()
        }
    }
}

/// Slim strip above the terminal: name, live status, folder and stop/start.
struct SessionHeader: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @Binding var showFiles: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let tab = store.selectedTab {
                let rt = store.runtime[tab.id] ?? TabRuntime()
                Circle()
                    .fill(rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(tab.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if [.claude, .codex].contains(store.provider(of: tab)) {
                    Text(store.provider(of: tab).label).font(.caption2).foregroundStyle(.tertiary)
                }
                if let line = rt.statusLine(showFolder: false) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if rt.awaitsPermission {
                    PermissionButtons(tabID: tab.id).controlSize(.mini)
                }
                Spacer()
                if store.provider(of: tab) == .codex {
                    CodexAgents(tabID: tab.id, compact: true)
                } else { AgentPill(tabID: tab.id) }
                if let worktree = tab.worktree {
                    PullRequestChip(tabID: tab.id)
                    BranchChip(tabID: tab.id, worktree: worktree)
                } else if let cwd = rt.cwd {
                    Text((cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if rt.busy {
                    Button { store.stop(tab.id) } label: { Image(systemName: "stop.fill") }
                        .help("Interrupt (Ctrl-C)")
                } else if !rt.agentConnected {
                    Button { store.start(tab.id) } label: { Image(systemName: "play.fill") }
                        .help("Start or continue this session")
                }
            } else {
                Spacer()
            }
            Button { showFiles.toggle() } label: { Image(systemName: "sidebar.trailing") }
                .foregroundStyle(showFiles ? .primary : .secondary)
                .help("Files panel (⌥⌘F)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: Store

    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { store.newTab() }.keyboardShortcut("t")
            Button("New Codex Session") { store.newTab(command: "codex") }
            Button("New Claude Code Session") { store.newTab(command: "claude") }
            Button("New Shell") { store.newTab(command: "") }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Session in Worktree…") {
                if let id = store.selectedGroup?.id ?? store.groups.first?.id { store.newWorktreeGroupID = id }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            Button("New Project") { store.newGroup() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Folder…") { store.openFolderPanel() }.keyboardShortcut("o")
            Button("Open Recent Conversation…") { store.showRecentSessions = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Session") { if let id = store.selectedTabID { store.requestClose(id) } }
                .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Files Panel") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Prefs.showFiles), forKey: Prefs.showFiles)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Files") { store.showPanel(.files) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Changes") { store.showPanel(.changes) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Browser") { store.showPanel(.browser) }.keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Bigger") { Fonts.adjustSize(by: 1) }.keyboardShortcut("+")
            Button("Smaller") { Fonts.adjustSize(by: -1) }.keyboardShortcut("-")
            Button("Default Font Size") { Fonts.adjustSize(by: nil) }.keyboardShortcut("0")
        }
        CommandMenu("Session") {
            Button("Rename") { store.renamingID = store.selectedTabID }.keyboardShortcut("r")
            Button("Edit Session…") { store.editingTabID = store.selectedTabID }.keyboardShortcut("i")
            Button("Restart Session") { if let id = store.selectedTabID { store.restart(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Interrupt (Ctrl-C)") { if let id = store.selectedTabID { store.stop(id) } }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Kill Session") { if let id = store.selectedTabID { store.kill(id) } }
            Button("Start or Continue Session") { if let id = store.selectedTabID { store.start(id) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button("Jump to Session…") { store.showQuickSwitcher = true }.keyboardShortcut("k")
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to omux…") { store.showWelcome = true }
            Button("omux on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/onurozcan/omux")!) }
            Button("Next Session") { store.selectRelative(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Session") { store.selectRelative(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1 ..< 10, id: \.self) { n in
                Button("Session \(n)") { store.selectIndex(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
            }
        }
    }
}

/// Finder's right-click "Open in omux" on folders (declared under NSServices in Info.plist).
final class ServiceProvider: NSObject {
    @objc func openFolders(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.openWindow?(id: "main")
            urls.forEach { Store.shared.openFolder($0.path) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openWindow: OpenWindowAction?
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Notifier.shared.activate()
        _ = Updater.shared
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Fonts.isBiggerKey(event.charactersIgnoringModifiers, event.modifierFlags) else { return event }
            Fonts.adjustSize(by: 1)
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Folders dropped on the Dock icon, opened via Finder's "Open With", or `open -a omux <dir>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.openWindow?(id: "main")
        urls.forEach { Store.shared.openFolder($0.path) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openWindow?(id: "main") }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = Store.shared
        let running = store.runningSessionCount
        let confirm = UserDefaults.standard.object(forKey: Prefs.confirmQuit) as? Bool ?? true
        if confirm, running > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit omux?"
            alert.informativeText = "\(running) session\(running == 1 ? " is" : "s are") running. Agent conversation IDs are saved so you can continue them next launch."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store.prepareForTermination()
        return .terminateNow
    }
}
