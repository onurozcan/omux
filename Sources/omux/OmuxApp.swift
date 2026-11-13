import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct OmuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared
    @AppStorage(Prefs.accent) private var accent = "system"
    @AppStorage(Prefs.theme) private var themeName = Theme.dark.rawValue

    init() { Prefs.importReleaseSettingsIfBeta() }

    var body: some Scene {
        Window(Persistence.isBeta ? "omux Beta" : "omux", id: "main") {
            ContentView()
                .environmentObject(store)
                .tint(Color(nsColor: Appearance.accent(accent, theme: Theme(rawValue: themeName) ?? .dark)))
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        // Folders and omux:// links go to the app delegate. Left to SwiftUI, an open event closes
        // the window to route it, and closing the main window is how omux quits.
        .handlesExternalEvents(matching: [])
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
    static let showSidebar = "showSidebar"
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
    /// Sessions get the `omux` command line tool. On by default.
    static let cliEnabled = "cliEnabled"
    /// Which agent ▶ starts in a plain shell session: "claude" or "codex".
    static let playAgent = "playAgent"
    /// What ▶ does for an agent with no saved conversation: "fresh" or "continue" (the folder's latest).
    static let startWithoutHistory = "startWithoutHistory"
    /// How agent sessions show in the main panel: "terminal" (default) or "transcript" (beta).
    static let sessionView = "sessionView"
    static let accent = "accent"
    static let transcriptFont = "transcriptFont"
    static let transcriptSize = "transcriptSize"
    static let transcriptWidth = "transcriptWidth"
    static let transcriptDensity = "transcriptDensity"
    static let transcriptBubbles = "transcriptBubbles"
    static let transcriptTimestamps = "transcriptTimestamps"

    static let all = [confirmQuit, showFolderPath, usageInterval, theme, autoResume, showFiles, showSidebar, filesByDate,
                      filesBrowserCollapsed, previewWrapLines, panelTab, fontFamily, fontSize,
                      notifyNeedsYou, notifyDone, notifyPrograms, cliEnabled, playAgent, startWithoutHistory,
                      sessionView, accent, transcriptFont, transcriptSize, transcriptWidth, transcriptDensity, transcriptBubbles, transcriptTimestamps]

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
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            SessionSettings()
                .tabItem { Label("Sessions", systemImage: "terminal") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            Form { UpdateSettings() }
                .formStyle(.grouped)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        // A fixed height: the grouped forms scroll inside it, so the tallest tab never pushes
        // the window off the screen.
        .frame(width: 540, height: 600)
    }
}

/// A one-line explanation under a setting.
private struct SettingNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true
    @AppStorage(Prefs.confirmQuit) private var confirmQuit = true

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show the folder path under each session", isOn: $showFolderPath)
                Picker("Check Claude usage limits every", selection: $usageInterval) {
                    Text("Minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("30 minutes").tag(1800.0)
                    Text("Hour").tag(3600.0)
                }
            }
            Section("Files") {
                Toggle("Wrap long lines in the file preview", isOn: $wrapLines)
            }
            Section("Quitting") {
                Toggle("Ask before quitting while sessions are running", isOn: $confirmQuit)
                SettingNote("Quitting stops every session. Saved Claude Code and Codex conversations continue on the next launch.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @AppStorage(Prefs.theme) private var theme = Theme.dark.rawValue
    @AppStorage(Prefs.accent) private var accent = "system"
    @AppStorage(Prefs.fontFamily) private var fontFamily = ""
    @AppStorage(Prefs.fontSize) private var fontSize = Fonts.defaultSize
    @AppStorage(Prefs.transcriptFont) private var transcriptFont = ""
    @AppStorage(Prefs.transcriptSize) private var transcriptSize = 13.0
    @AppStorage(Prefs.transcriptWidth) private var transcriptWidth = "full"
    @AppStorage(Prefs.transcriptDensity) private var transcriptDensity = "comfortable"
    @AppStorage(Prefs.transcriptBubbles) private var transcriptBubbles = "tinted"
    @AppStorage(Prefs.transcriptTimestamps) private var transcriptTimestamps = true

    private var current: Theme { Theme(rawValue: theme) ?? .dark }

    var body: some View {
        Form {
            Section("Theme") {
                swatches("Dark", Theme.darkThemes)
                swatches("Light", Theme.lightThemes)
                SettingNote("Colours for terminals, the transcript view, the file editor and the window.")
            }
            Section("Accent") {
                Picker("Accent colour", selection: $accent) {
                    ForEach(Appearance.accents, id: \.id) { choice in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: Appearance.accent(choice.id, theme: current))).frame(width: 10, height: 10)
                            Text(choice.label)
                        }
                        .tag(choice.id)
                    }
                }
                SettingNote("Buttons, selection, links and the send button. Theme uses the theme's own blue. Neutral is grey everywhere but the sidebar, which keeps the system's colour.")
            }
            Section("Terminal") {
                Picker("Font", selection: $fontFamily) {
                    Text("System Mono").tag("")
                    ForEach(Fonts.monospaceFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: Fonts.sizes)
                SettingNote("Also the font of code in the transcript and the file editor. ⌘+ and ⌘− change the size.")
            }
            Section("Transcript") {
                Picker("Font", selection: $transcriptFont) {
                    ForEach(Appearance.transcriptFonts, id: \.id) { Text($0.label).tag($0.id) }
                }
                Stepper("Size: \(Int(transcriptSize)) pt", value: $transcriptSize, in: Appearance.transcriptSizes)
                Picker("Width", selection: $transcriptWidth) {
                    ForEach(Appearance.widths, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
                Picker("Density", selection: $transcriptDensity) {
                    ForEach(Appearance.densities, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
                Picker("Your messages", selection: $transcriptBubbles) {
                    ForEach(Appearance.bubbles, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
                Toggle("Show the time under your messages", isOn: $transcriptTimestamps)
                SettingNote("Applies to every open transcript at once.")
            }
        }
        .formStyle(.grouped)
    }

    /// A row of theme cards: background, chrome strip, sample text and six palette colours.
    private func swatches(_ title: String, _ themes: [Theme]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(themes) { option in
                    Button { theme = option.rawValue } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 4) {
                                Text("Aa").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: option.foreground))
                                Spacer()
                                ForEach(Array(option.swatch.enumerated()), id: \.offset) { _, color in
                                    Circle().fill(Color(nsColor: color)).frame(width: 6, height: 6)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 7)
                            .background(Color(nsColor: option.background))
                            Text(option.label)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .foregroundStyle(Color(nsColor: option.foreground))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: option.chrome))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(option == current ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: option == current ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SessionSettings: View {
    @AppStorage(Prefs.sessionView) private var sessionView = "terminal"
    @AppStorage(Prefs.playAgent) private var playAgent = "claude"
    @AppStorage(Prefs.startWithoutHistory) private var startWithoutHistory = "fresh"
    @AppStorage(Prefs.autoResume) private var autoResume = false
    @AppStorage(Prefs.cliEnabled) private var cliEnabled = true

    var body: some View {
        Form {
            Section("View") {
                Picker("Show agent sessions as", selection: $sessionView) {
                    Text("Terminal").tag("terminal")
                    Text("Transcript").tag("transcript")
                }
                .pickerStyle(.radioGroup)
                SettingNote(sessionView == "transcript"
                    ? "Every session is a chat, read from Claude Code's transcript or Codex's thread, with a box that types into the terminal. The terminal keeps running underneath; ⌥⌘P peeks at it. A project can choose its own view in its settings."
                    : "Every session is its terminal. Transcript shows the same sessions as chat, with a compose box; a project can choose its own view in its settings.")
            }
            Section("Starting") {
                Picker("▶ in a shell starts", selection: $playAgent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                Picker("An agent with no saved conversation", selection: $startWithoutHistory) {
                    Text("Starts fresh").tag("fresh")
                    Text("Continues the folder's latest conversation").tag("continue")
                }
                SettingNote("Continuing runs claude --continue. Codex always starts fresh. ▶ in a plain shell of a project that has conversations resumes the latest one either way.")
                Toggle("Resume agent sessions at launch", isOn: $autoResume)
                SettingNote("Off: restored sessions stay stopped until you press ▶. Clicking one only opens its shell.")
            }
            Section("Integration") {
                Toggle("Give sessions the omux command", isOn: $cliEnabled)
                SettingNote("Programs in a session can run omux to list the project's sessions, read their screens, and start sessions of their own. Applies to sessions started after the change.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @AppStorage(Prefs.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDone) private var notifyDone = false
    @AppStorage(Prefs.notifyPrograms) private var notifyPrograms = true
    @AppStorage(Prefs.notifyStyle) private var notifyStyle = "banner"
    @AppStorage(Prefs.notifySound) private var notifySound = "Default"

    var body: some View {
        Form {
            Section("Notify me") {
                Toggle("When a session needs me", isOn: $notifyNeedsYou)
                Toggle("When a session finishes", isOn: $notifyDone)
                Toggle("When a program in a session sends one", isOn: $notifyPrograms)
                SettingNote("Only for sessions you aren't looking at. Programs send them with OSC 9 or OSC 777; set Claude Code's notification channel to ghostty (/config) to get its plugins' notifications too.")
            }
            Section("Style") {
                Picker("Show as", selection: $notifyStyle) {
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
    }
}

/// Keeps the close, minimize and zoom buttons visible while the toolbar is hidden. Hiding the
/// window toolbar removes them on some macOS versions; keeping the toolbar instead leaves an
/// invisible strip that pushes the content down and swallows clicks on the sidebar's buttons.
/// Closing this (the main) window quits omux, so its sessions don't keep running in the background.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        DispatchQueue.main.async { ChromeView.configure(view.window) }
    }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            DispatchQueue.main.async { Self.configure(window) }
            // SwiftUI hides the buttons again whenever it updates the window, which happens at no
            // fixed moment (switching sessions, opening panels, resizing). didUpdate comes after every
            // event the window handles, and configure only writes what has changed, so it stays cheap.
            let refresh: [Notification.Name] = [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                                                NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification]
            for name in refresh {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { Self.configure(window) }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { AppDelegate.mainWindowWillClose(window) }
            })
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        static func configure(_ window: NSWindow?) {
            guard let window else { return }
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            if !window.styleMask.isSuperset(of: style) { window.styleMask.formUnion(style) }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            // In full screen macOS slides the title bar in and out itself; forcing it visible there
            // would pin it over the sessions.
            let fullScreen = window.styleMask.contains(.fullScreen)
            let frameView = window.contentView?.superview
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                if button.isHidden { button.isHidden = false }
                if button.alphaValue < 1 { button.alphaValue = 1 }
                guard !fullScreen else { continue }
                // Hiding the window toolbar can hide the title bar view that holds the buttons, so
                // showing the buttons alone isn't enough. Walk up to the window's frame view.
                var parent = button.superview
                while let view = parent, view !== frameView {
                    if view.isHidden { view.isHidden = false }
                    if view.alphaValue < 1 { view.alphaValue = 1 }
                    parent = view.superview
                }
            }
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
    @AppStorage(Prefs.showSidebar) private var showSidebar = true
    @AppStorage(Prefs.accent) private var accentChoice = "system"
    @AppStorage("panelWidth") private var panelWidth = 250.0

    /// The sidebar closes like the right panel does, and stays closed across launches.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { showSidebar ? .all : .detailOnly }, set: { showSidebar = $0 != .detailOnly })
    }

    private var theme: Theme { Theme(rawValue: themeName) ?? .dark }

    /// Changes follow the selected session and its folder, which may be its project's.
    private var changesKey: String {
        let tab = store.selectedTab
        return "\(tab?.id.uuidString ?? "")|\(tab.flatMap(store.directory(of:)) ?? "")|\(tab?.worktree?.branch ?? "")"
    }

    /// Folder the file panel shows: the selected session's folder, else its project's.
    private var projectRoot: URL {
        let tab = store.selectedTab
        let group = store.selectedGroup
        let path = tab?.directory ?? group?.directory ?? NSHomeDirectory()
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columns) {
            Sidebar(theme: theme)
                // Neutral leaves the sidebar its colour: the rest of the window goes grey.
                .tint(Color(nsColor: accentChoice == "neutral" ? .controlAccentColor : Appearance.accent(accentChoice, theme: theme)))
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SessionHeader(theme: theme, showFiles: $showFiles, showSidebar: $showSidebar)
                        // Above the panes: their layout is measured with GeometryReader, which
                        // otherwise paints over the header.
                        .zIndex(1)
                    // Over the terminal, so a notice doesn't resize the session.
                    ZStack(alignment: .top) {
                        if let shown = store.shownLayout {
                            PaneTree(node: shown, theme: theme)
                                .background(Color(nsColor: theme.chrome))
                        } else if let id = store.selectedTabID, let term = store.terminal(for: id) {
                            DropIntoPane(target: id) { hooks in
                                SessionSurface(tabID: id, theme: theme, hooks: hooks) {
                                    TerminalHost(termView: term, theme: theme, onDragEdge: hooks.edgeChanged, onDropSession: hooks.dropped)
                                }
                            }
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
                    // As narrow as the sidebar by default; the handle on its edge resizes it.
                    PanelHandle(width: $panelWidth)
                    RightPanel(root: projectRoot, theme: theme)
                        .frame(width: panelWidth)
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
            // The transcript's page is loaded before the first session asks for it.
            if UserDefaults.standard.string(forKey: Prefs.sessionView) == "transcript" || store.groups.contains(where: { $0.sessionView == "transcript" }) {
                TranscriptPages.shared.warm("single")
            }
        }
    }
}

/// Slim strip above the terminal: name, live status, folder and stop/start.
struct SessionHeader: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @Binding var showFiles: Bool
    @Binding var showSidebar: Bool

    var body: some View { WithRuntime(store.selectedTabID) { _ in sessionBody } }

    /// Drawn again whenever this session's live state changes; see `WithRuntime`.
    @ViewBuilder private var sessionBody: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } } label: { Image(systemName: "sidebar.leading") }
                .foregroundStyle(showSidebar ? .primary : .secondary)
                .help("Sidebar (⌃⌘S)")
            if let shown = store.shownLayout {
                // Every pane has its own header; this one names the project they belong to.
                Image(systemName: "folder").foregroundStyle(.tertiary)
                Text(store.selectedGroup?.name ?? "Panes")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(shown.ids.count) panes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let tab = store.selectedTab {
                let rt = store.runtime[tab.id] ?? TabRuntime()
                StatusDot(color: rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.4), pulsing: rt.statusState == .working, size: 8)
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
                    Button { store.stop(tab.id) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 8)).frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .help("Interrupt (Ctrl-C)")
                } else if !rt.agentConnected {
                    Button { store.start(tab.id) } label: {
                        Image(systemName: "play.fill").font(.system(size: 8)).frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .help("Start or continue this session")
                }
            } else {
                Spacer()
            }
            if store.isMaximized {
                Button { store.restoreSplit() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("Back to side by side")
            } else if let id = store.selectedTabID {
                // The way into panes from a single session: a shell beside or below it.
                Button { store.splitWithShell(id, axis: .horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("New shell to the right, in this session's folder")
                Button { store.splitWithShell(id, axis: .vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("New shell below, in this session's folder")
            }
            Button { showFiles.toggle() } label: { Image(systemName: "sidebar.trailing") }
                .foregroundStyle(showFiles ? .primary : .secondary)
                .help("Files panel (⌥⌘F)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        // With the sidebar closed the header reaches the window's corner: room for its buttons.
        .padding(.leading, showSidebar ? 0 : 68)
        .frame(height: 28)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }
}

/// The layout tree as nested splits. There's no divider to see: the gutter between two
/// cards is the handle, and dragging it resizes them.
struct PaneTree: View {
    @EnvironmentObject var store: Store
    let node: PaneLayout
    let theme: Theme
    var path: [Bool] = []

    var body: some View {
        switch node {
        case .session(let id):
            // The selected pane gets a light border; the others a hairline.
            let selected = store.selectedTabID == id
            SplitPane(tabID: id, theme: theme)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.primary.opacity(0.45) : Color.primary.opacity(0.1), lineWidth: 1))
                .padding(4)
                .animation(.easeOut(duration: 0.12), value: selected)
        case .split(let axis, let fraction, let first, let second):
            GeometryReader { geo in
                let total = axis == .horizontal ? geo.size.width : geo.size.height
                let firstSize = (total * fraction).rounded()
                let handle = Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .frame(width: axis == .horizontal ? 10 : nil, height: axis == .vertical ? 10 : nil)
                    .onHover { inside in
                        if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("pane-split"))
                        .onChanged { value in
                            let position = axis == .horizontal ? value.location.x : value.location.y
                            store.resizePane(path: path, fraction: position / max(total, 1))
                        })
                ZStack(alignment: .topLeading) {
                    if axis == .horizontal {
                        HStack(spacing: 0) {
                            PaneTree(node: first, theme: theme, path: path + [false]).frame(width: firstSize)
                            PaneTree(node: second, theme: theme, path: path + [true])
                        }
                        handle.frame(maxHeight: .infinity).offset(x: firstSize - 5)
                    } else {
                        VStack(spacing: 0) {
                            PaneTree(node: first, theme: theme, path: path + [false]).frame(height: firstSize)
                            PaneTree(node: second, theme: theme, path: path + [true])
                        }
                        handle.frame(maxWidth: .infinity).offset(y: firstSize - 5)
                    }
                }
                .coordinateSpace(name: "pane-split")
            }
        }
    }
}

/// One session in the layout: a slim header with its controls, then its terminal. A click
/// anywhere selects it; the header can be dragged onto another pane's edge to move it.
struct SplitPane: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let theme: Theme
    var body: some View { WithRuntime(tabID) { _ in sessionBody } }

    /// Drawn again whenever this session's live state changes; see `WithRuntime`.
    @ViewBuilder private var sessionBody: some View {
        let selected = store.selectedTabID == tabID
        DropIntoPane(target: tabID) { hooks in
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let tab = store.tab(tabID) {
                    let rt = store.runtime[tabID] ?? TabRuntime()
                    StatusDot(color: rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.4), pulsing: rt.statusState == .working, size: 7)
                    Text(tab.name)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    if let line = rt.statusLine(showFolder: false) {
                        Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if rt.awaitsPermission {
                        PermissionButtons(tabID: tabID).controlSize(.mini)
                    }
                }
                Spacer()
                Button { store.splitWithShell(tabID, axis: .horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                    .disabled(store.splitIDs.count >= PaneLayout.maxPanes)
                    .help("New shell to the right, in this session's folder")
                Button { store.splitWithShell(tabID, axis: .vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                    .disabled(store.splitIDs.count >= PaneLayout.maxPanes)
                    .help("New shell below, in this session's folder")
                Button { store.maximize(tabID) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Show only this session; the layout stays")
                Button { store.removeFromSplit(tabID) } label: { Image(systemName: "xmark") }
                    .help("Close this pane (the session keeps running)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color(nsColor: theme.chrome))
            .contentShape(Rectangle())
            .onTapGesture { focus() }
            .onDrag { NSItemProvider(object: tabID.uuidString as NSString) }
            .help("Drag onto another pane's edge to move this session there")
            .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? Color.accentColor.opacity(0.8) : .primary.opacity(0.08)).frame(height: 1)
            }
            if let term = store.terminal(for: tabID) {
                SessionSurface(tabID: tabID, theme: theme, slot: tabID.uuidString, hooks: hooks) {
                    TerminalHost(termView: term, theme: theme, onClick: {
                        if store.selectedTabID != tabID { store.selectedTabID = tabID }
                    }, onDragEdge: hooks.edgeChanged, onDropSession: hooks.dropped)
                }
                .onTapGesture { if store.selectedTabID != tabID { store.selectedTabID = tabID } }
            } else {
                Color(nsColor: theme.background)
            }
        }
        }
        .onChange(of: store.selectedTabID) { _, id in
            if id == tabID, !SessionViewMode.showsTranscript(tabID, store: store),
               let term = store.terminal(for: tabID), term.window?.firstResponder !== term {
                term.window?.makeFirstResponder(term)
            }
        }
    }

    private func focus() {
        store.selectedTabID = tabID
        if !SessionViewMode.showsTranscript(tabID, store: store), let term = store.terminal(for: tabID) {
            term.window?.makeFirstResponder(term)
        }
    }
}

/// The edge of the right panel: a hairline you can drag to resize it.
struct PanelHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if startWidth == nil { startWidth = width }
                            width = min(max((startWidth ?? width) - value.translation.width, 220), 900)
                        }
                        .onEnded { _ in startWidth = nil })
            }
    }
}

/// What a terminal container reports while a session is dragged over it.
struct DropHooks {
    let edgeChanged: (Edge?) -> Void
    let dropped: (UUID, Edge) -> Void
}

/// Lets a session be dropped on the content's edges: from the sidebar, or from another pane.
struct DropIntoPane<Content: View>: View {
    @EnvironmentObject var store: Store
    let target: UUID
    @ViewBuilder let content: (DropHooks) -> Content
    @State private var dropEdge: Edge?
    @State private var size: CGSize = .zero

    var body: some View {
        content(DropHooks(edgeChanged: { dropEdge = $0 }, dropped: { id, edge in store.dropSession(id, on: target, edge: edge) }))
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { size = geo.size; store.paneSizes[target] = geo.size }
                    .onChange(of: geo.size) { _, new in size = new; store.paneSizes[target] = new }
            })
            .overlay { highlight }
            .onDrop(of: [.plainText], delegate: PaneDropDelegate(target: target, edge: $dropEdge, size: size, store: store))
            // A drop a child takes (a file onto the compose box) never reports exiting, so the
            // highlight would stay; it goes once the mouse is up.
            .task(id: dropEdge != nil) {
                guard dropEdge != nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    if NSEvent.pressedMouseButtons == 0 { dropEdge = nil; return }
                }
            }
    }

    /// Where the dragged session would land: the half of this pane on that edge.
    @ViewBuilder private var highlight: some View {
        if let edge = dropEdge {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let rect: CGRect = switch edge {
                case .leading: CGRect(x: 0, y: 0, width: w / 2, height: h)
                case .trailing: CGRect(x: w / 2, y: 0, width: w / 2, height: h)
                case .top: CGRect(x: 0, y: 0, width: w, height: h / 2)
                case .bottom: CGRect(x: 0, y: h / 2, width: w, height: h / 2)
                }
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Takes a dragged session and puts it on the edge of this pane nearest to where it was dropped.
struct PaneDropDelegate: DropDelegate {
    let target: UUID
    @Binding var edge: Edge?
    let size: CGSize
    let store: Store

    /// A session from the sidebar, not a file or image dragged in from elsewhere.
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) && !info.hasItemsConforming(to: [.fileURL, .image]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = Self.edge(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = edge ?? Self.edge(at: info.location, in: size)
        edge = nil
        guard let item = info.itemProviders(for: [.plainText]).first else { return false }
        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { store.dropSession(id, on: target, edge: landing) }
        }
        return true
    }

    /// The edge of the pane the point is nearest to, each distance taken as a share of that
    /// side, so a wide pane doesn't favour its top and bottom.
    static func edge(at point: CGPoint, in size: CGSize) -> Edge {
        guard size.width > 0, size.height > 0 else { return .trailing }
        let shares: [(Edge, CGFloat)] = [(.leading, point.x / size.width), (.trailing, 1 - point.x / size.width),
                                         (.top, point.y / size.height), (.bottom, 1 - point.y / size.height)]
        return shares.min(by: { $0.1 < $1.1 })?.0 ?? .trailing
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
            Button("Sidebar") {
                let shown = UserDefaults.standard.object(forKey: Prefs.showSidebar) as? Bool ?? true
                UserDefaults.standard.set(!shown, forKey: Prefs.showSidebar)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Files Panel") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Prefs.showFiles), forKey: Prefs.showFiles)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Files") { store.showPanel(.files) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Changes") { store.showPanel(.changes) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Browser") { store.showPanel(.browser) }.keyboardShortcut("3", modifiers: [.command, .option])
            Button("Agents") { store.showPanel(.agents) }.keyboardShortcut("4", modifiers: [.command, .option])
            Button("Terminal Behind Transcript") {
                guard let id = store.selectedTabID else { return }
                if TerminalPeek.shared.tabs.contains(id) { TerminalPeek.shared.hide(id) } else { TerminalPeek.shared.show(id, store: store) }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button(store.selectedTabID.map { store.splitIDs.contains($0) } == true ? "Remove from Side by Side" : "Show Side by Side") {
                if let id = store.selectedTabID { store.toggleSplit(id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Tidy Panes") { store.tidyPanes() }
                .disabled(store.splitIDs.isEmpty)
            Button("Clear Panes") { store.clearSplit() }
                .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                .disabled(store.splitIDs.isEmpty)
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
            AppDelegate.showMainWindow()
            urls.forEach { Store.shared.openFolder($0.path) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openWindow: OpenWindowAction?
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShellPath.warmUp()
        ClaudeModels.shared.refresh()
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

    /// Brings the main window forward, opening it only when none is up.
    @MainActor static func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }

    /// Closing the main window quits omux, which stops every session, instead of leaving them
    /// running with no window. If the quit is cancelled in the confirmation, the window comes back.
    /// When a folder is opened from Finder, the Dock or `open -a omux`, SwiftUI also makes a window
    /// it never shows to route the event and closes it at once; that close must not quit omux.
    @MainActor static func mainWindowWillClose(_ window: NSWindow?) {
        guard let window, window.isVisible else { return }
        DispatchQueue.main.async {
            // Another window of the app is still up: this wasn't the last one.
            if NSApp.windows.contains(where: { $0 !== window && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }) { return }
            NSApp.terminate(nil)
            // Still here: the quit was cancelled.
            openWindow?(id: "main")
        }
    }

    /// Folders dropped on the Dock icon, opened via Finder's "Open With", or `open -a omux <dir>`,
    /// and `omux://reveal` links from other apps (see RevealLink).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !url.isFileURL {
            if let link = RevealLink(url), let id = Store.shared.tabID(for: link) { Store.shared.reveal(id) }
        }
        let folders = urls.filter(\.isFileURL)
        guard !folders.isEmpty else { return }
        Self.showMainWindow()
        folders.forEach { Store.shared.openFolder($0.path) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = Store.shared
        let running = store.runningSessionCount
        let confirm = UserDefaults.standard.object(forKey: Prefs.confirmQuit) as? Bool ?? true
        if confirm, running > 0 {
            let update = Updater.shared.installingVersion
            if Self.quitAlert(running: running, update: update).runModal() != .alertFirstButtonReturn {
                // Sparkle still installs the update when omux quits.
                Updater.shared.installingVersion = nil
                return .terminateCancel
            }
        }
        store.prepareForTermination()
        return .terminateNow
    }

    /// Asks before quitting stops running sessions. When Sparkle is quitting omux to install an
    /// update, says so, and that the update can wait.
    static func quitAlert(running: Int, update: String?) -> NSAlert {
        let alert = NSAlert()
        let sessions = "\(running) session\(running == 1 ? " is" : "s are") running."
        if let update {
            alert.messageText = "Relaunch to install omux \(update)?"
            alert.informativeText = "\(sessions) Relaunching stops them; agent conversation IDs are saved so you can continue them after the update. Choose Later to install it the next time you quit omux."
            alert.addButton(withTitle: "Relaunch")
            alert.addButton(withTitle: "Later")
        } else {
            alert.messageText = "Quit omux?"
            alert.informativeText = "\(sessions) Agent conversation IDs are saved so you can continue them next launch."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
        }
        return alert
    }
}
