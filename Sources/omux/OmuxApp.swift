import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// Sessions get the `omux` command line tool. On by default.
    static let cliEnabled = "cliEnabled"
    /// Which agent ▶ starts in a plain shell session: "claude" or "codex".
    static let playAgent = "playAgent"
    /// What ▶ does for an agent with no saved conversation: "fresh" or "continue" (the folder's latest).
    static let startWithoutHistory = "startWithoutHistory"

    static let all = [confirmQuit, showFolderPath, usageInterval, theme, autoResume, showFiles, filesByDate,
                      filesBrowserCollapsed, previewWrapLines, panelTab, fontFamily, fontSize,
                      notifyNeedsYou, notifyDone, notifyPrograms, cliEnabled, playAgent, startWithoutHistory]

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
    @AppStorage(Prefs.cliEnabled) private var cliEnabled = true
    @AppStorage(Prefs.playAgent) private var playAgent = "claude"
    @AppStorage(Prefs.startWithoutHistory) private var startWithoutHistory = "fresh"

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
                Picker("▶ in a shell session starts", selection: $playAgent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                Picker("An agent with no saved conversation", selection: $startWithoutHistory) {
                    Text("Starts fresh").tag("fresh")
                    Text("Continues the folder's latest conversation").tag("continue")
                }
                Text("Continuing uses claude --continue; Codex always starts fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Auto-resume agent sessions at launch", isOn: $autoResume)
                Text("Off: restored sessions stay stopped until you press ▶. Clicking one only opens its shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Confirm before quitting while sessions are running", isOn: $confirmQuit)
                Text("Quitting stops every session. Saved Claude Code and Codex conversations can be continued on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Give sessions the omux command", isOn: $cliEnabled)
                Text("Programs in a session can run `omux` to list the project's sessions, read their screens, and start sessions of their own to send text to. Takes effect for sessions started after the change.")
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
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AppDelegate.mainWindowWillClose() }
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
    @AppStorage("panelWidth") private var panelWidth = 250.0

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
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SessionHeader(theme: theme, showFiles: $showFiles)
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
                                TerminalHost(termView: term, theme: theme, onDragEdge: hooks.edgeChanged, onDropSession: hooks.dropped)
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
        .onAppear { AppDelegate.openWindow = openWindow }
    }
}

/// Slim strip above the terminal: name, live status, folder and stop/start.
struct SessionHeader: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @Binding var showFiles: Bool

    var body: some View {
        HStack(spacing: 10) {
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
            SplitPane(tabID: id, theme: theme)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.1), lineWidth: 1))
                .padding(4)
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
    var body: some View {
        let selected = store.selectedTabID == tabID
        DropIntoPane(target: tabID) { hooks in
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let tab = store.tab(tabID) {
                    let rt = store.runtime[tabID] ?? TabRuntime()
                    Circle()
                        .fill(rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
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
                TerminalHost(termView: term, theme: theme, onClick: {
                    if store.selectedTabID != tabID { store.selectedTabID = tabID }
                }, onDragEdge: hooks.edgeChanged, onDropSession: hooks.dropped)
            } else {
                Color(nsColor: theme.background)
            }
        }
        }
        .onChange(of: store.selectedTabID) { _, id in
            if id == tabID, let term = store.terminal(for: tabID), term.window?.firstResponder !== term {
                term.window?.makeFirstResponder(term)
            }
        }
    }

    private func focus() {
        store.selectedTabID = tabID
        if let term = store.terminal(for: tabID) { term.window?.makeFirstResponder(term) }
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

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

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
            Button("Files Panel") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Prefs.showFiles), forKey: Prefs.showFiles)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Files") { store.showPanel(.files) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Changes") { store.showPanel(.changes) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Browser") { store.showPanel(.browser) }.keyboardShortcut("3", modifiers: [.command, .option])
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

    /// Closing the main window quits omux, which stops every session, instead of leaving them
    /// running with no window. If the quit is cancelled in the confirmation, the window comes back.
    @MainActor static func mainWindowWillClose() {
        DispatchQueue.main.async {
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
        Self.openWindow?(id: "main")
        folders.forEach { Store.shared.openFolder($0.path) }
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
