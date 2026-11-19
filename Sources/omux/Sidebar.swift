import SwiftUI
import UniformTypeIdentifiers

/// One row of the flat sidebar list: a project header, a session, or a stack of idle shells.
enum SidebarRow: Identifiable, Hashable {
    case group(TabGroup)
    case tab(TabItem, groupID: UUID)
    /// A shell listed under its stack, indented with a guide line.
    case nested(TabItem, groupID: UUID)
    /// Idle shells of a project folded into one row; `expanded` lists them below it.
    case shells(groupID: UUID, tabs: [TabItem], expanded: Bool)
    /// Projects with nothing running folded into one row at the bottom.
    case projects(groups: [TabGroup], expanded: Bool)

    var id: UUID {
        switch self {
        case .group(let g): return g.id
        case .tab(let t, _), .nested(let t, _): return t.id
        case .shells(let g, _, _):
            // Derived from the project's id, so it never collides with a session's.
            var bytes = g.uuid
            bytes.15 ^= 0xFF
            return UUID(uuid: bytes)
        case .projects:
            return UUID(uuidString: "00000000-0000-0000-0000-00000000bead")!
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    /// Projects whose idle shells are listed instead of stacked.
    @State private var expandedShells: Set<UUID> = []
    /// Idle projects listed instead of stacked.
    @State private var expandedProjects = false
    /// "rail": projects on a narrow strip of initials, with one project's sessions listed beside
    /// it. "list": every project and its sessions in one list.
    @AppStorage(Prefs.sidebarLayout) private var layout = "rail"
    /// Which project the list shows and whether the strip is open; shared with the strip's
    /// other home, at the window's edge when this list is closed.
    @ObservedObject private var railState = RailState.shared

    private var rail: Bool { layout == "rail" }
    private var shownGroup: TabGroup? {
        store.groups.first { $0.id == railState.shownGroupID } ?? store.selectedGroup ?? store.groups.first
    }

    /// The shown project's rows with its header first, as `moveRows` expects; the list leaves the header out.
    private var railRows: [SidebarRow] {
        guard var group = shownGroup else { return [] }
        group.isCollapsed = false
        return groupRows(group)
    }

    /// Pinned projects first, then the active projects in the order they were activated, latest first (a
    /// project moves to the top when an agent starts in it or returns after an hour, and stays put
    /// while it is prompted; drags and Move Up/Down hold), then the idle ones; two or more idle projects fold into one row at the bottom. Within a project, two or more idle shells fold into one
    /// row, so agents stay in view. The flat list lets native drag reorder and move sessions.
    private var rows: [SidebarRow] {
        // Pinned projects first, in their order; then the rest of the active ones in theirs.
        let working = store.groups.filter { store.isActive($0) }
        let active = working.filter(\.pinned) + working.filter { !$0.pinned }
        // Idle projects most recently used first, so the one you'll come back to is on top.
        let idle = store.groups.filter { !store.isActive($0) }.sorted { store.lastActivity($0) > store.lastActivity($1) }
        var rows = active.flatMap(groupRows)
        if idle.count >= 2 {
            // Clicking never reorders: a selected session inside the stack opens the stack instead.
            let holdsSelection = idle.contains { group in group.tabs.contains { $0.id == store.selectedTabID } }
            let expanded = expandedProjects || holdsSelection
            rows.append(.projects(groups: idle, expanded: expanded))
            if expanded { rows += idle.flatMap(groupRows) }
        } else {
            rows += idle.flatMap(groupRows)
        }
        return rows
    }

    private func groupRows(_ group: TabGroup) -> [SidebarRow] {
        return { () -> [SidebarRow] in
            guard !group.isCollapsed else { return [.group(group)] }
            // Most recently used first, so the shell you'll want is at the top of the stack.
            let idle = group.tabs.filter { isIdleShell($0) }
                .sorted { (store.runtime[$0.id]?.lastActivity ?? .distantPast) > (store.runtime[$1.id]?.lastActivity ?? .distantPast) }
            guard idle.count >= 2 else { return [.group(group)] + group.tabs.map { .tab($0, groupID: group.id) } }
            let expanded = expandedShells.contains(group.id) || idle.contains { $0.id == store.selectedTabID }
            var rows: [SidebarRow] = [.group(group)]
            var stacked = false
            for tab in group.tabs {
                if idle.contains(tab) {
                    if !stacked {
                        rows.append(.shells(groupID: group.id, tabs: idle, expanded: expanded))
                        if expanded { rows += idle.map { .nested($0, groupID: group.id) } }
                        stacked = true
                    }
                } else {
                    rows.append(.tab(tab, groupID: group.id))
                }
            }
            return rows
        }()
    }

    /// A plain shell with nothing running in it. Selecting one keeps its stack open rather
    /// than pulling it out, so the list doesn't shuffle under the click.
    private func isIdleShell(_ tab: TabItem) -> Bool {
        guard store.provider(of: tab) == .shell else { return false }
        let rt = store.runtime[tab.id]
        return rt == nil || rt!.exited || !rt!.busy
    }

    var body: some View {
        // In the rail layout the list is one project's rows without its header; otherwise all of them.
        let all = rail ? railRows : rows
        let skipped = rail ? min(1, all.count) : 0
        let shown = Array(all.dropFirst(skipped))
        // The strip keeps its place; opened under the pointer, it lies over the list.
        return HStack(spacing: 0) {
            if rail { Color.clear.frame(width: ProjectRail.width) }
            listColumn(all: all, skipped: skipped, shown: shown)
                .padding(.bottom, Glass.gap)
                .padding(.leading, Glass.gap)
                // Under the open strip the list takes nothing: not a click, not a hover.
                .allowsHitTesting(!(rail && railState.open))
                .environment(\.hoverBlocked, rail && railState.open)
        }
        .overlay(alignment: .leading) {
            if rail {
                ZStack(alignment: .leading) {
                    if railState.open {
                        // Whatever misses the strip lands here, not on a row behind it.
                        Color.black.opacity(0.001).onTapGesture { railState.open = false }
                    }
                    // A click goes to the project, on the session last on show in it.
                    ProjectRail(shownID: shownGroup?.id, theme: theme, open: $railState.open) { group in railState.show(group, in: store) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .onChange(of: store.selectedTabID) { _, _ in
            // The list follows the selection to its project, wherever it was made.
            railState.noteSelection(in: store)
        }
        .background(Glass.backdrop(theme))
        .contextMenu {
            // Empty-space menu; rows and project headers override it with their own.
            Button("New Project") { store.newGroup() }
            Button("New Remote Project…") { store.showRemoteProject = true }
            Button("Open Folder as Project…") { store.openFolderPanel() }
            Button("Open Recent Conversation…") { store.showRecentSessions = true }
            Button("New Codex Session") { store.newTab(command: "codex") }
            Divider()
            Button("New Session") { store.newTab() }
            Button("New Shell") { store.newTab(command: "") }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { store.openFolder(url.path) }
                }
            }
            return true
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
    }

    @ViewBuilder
    private func listColumn(all: [SidebarRow], skipped: Int, shown: [SidebarRow]) -> some View {
        VStack(spacing: 0) {
            // Traffic lights occupy the top-left; actions sit on the right.
            HStack(spacing: 2) {
                Spacer()
                Button { if let group = shownGroup, rail { store.newTab(in: group.id) } else { store.newTab() } } label: { Image(systemName: "plus") }
                    .help("New session in current project (⌘T)")
                if !rail {
                    Button { store.openFolderPanel() } label: { Image(systemName: "folder.badge.plus") }
                        .help("Open folder as a project (⌘O)")
                    Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("Open recent conversation (⇧⌘O)")
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)")
                }
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .frame(height: 28)
            // The list grows into the title bar's safe area when it touches it, which would put it
            // over the buttons and take their clicks. A 1pt gap keeps it below them.
            Spacer(minLength: 0).frame(height: 1)
            // The card starts under the window's buttons, which lie over this column's corner.
            VStack(spacing: 0) {
            if rail, let group = shownGroup { RailProjectTitle(group: group) }

            // No selection binding: the system's selection is a solid bar. Rows select themselves
            // on a click and draw their own highlight.
            List {
                ForEach(shown) { row in
                    switch row {
                    case .group(let group):
                        GroupHeader(group: group)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                    case .tab(let tab, let groupID):
                        SoftRow(selected: store.selectedTabID == tab.id) { store.selectedTabID = tab.id } content: { TabRow(tab: tab).padding(.leading, rail ? 2 : 8) }
                            .contextMenu { TabMenu(tab: tab, groupID: groupID) }
                            // Dragged onto a terminal's edge, the session is shown there in a pane.
                            // (itemProvider keeps the List's own drag, so reordering and clicks still work.)
                            .itemProvider { NSItemProvider(object: tab.id.uuidString as NSString) }
                    case .nested(let tab, let groupID):
                        SoftRow(selected: store.selectedTabID == tab.id) { store.selectedTabID = tab.id } content: {
                            TabRow(tab: tab)
                                .padding(.leading, 20)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(.primary.opacity(0.12)).frame(width: 1).padding(.leading, 12)
                                }
                        }
                            .contextMenu { TabMenu(tab: tab, groupID: groupID) }
                            .itemProvider { NSItemProvider(object: tab.id.uuidString as NSString) }
                    case .shells(let groupID, let tabs, let expanded):
                        StackRow(title: "Idle shells", count: tabs.count, expanded: expanded) {
                            if expanded { expandedShells.remove(groupID) } else { expandedShells.insert(groupID) }
                        }
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        .padding(.leading, 4)
                        .help(tabs.map(\.name).joined(separator: ", "))
                        .contextMenu {
                            Button(expanded ? "Stack idle shells" : "Show idle shells") {
                                if expanded { expandedShells.remove(groupID) } else { expandedShells.insert(groupID) }
                            }
                            Button("Close idle shells") { for tab in tabs { store.requestClose(tab.id) } }
                        }
                    case .projects(let groups, let expanded):
                        StackRow(title: "Idle projects", count: groups.count, expanded: expanded) { expandedProjects.toggle() }
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                            .padding(.top, 6)
                            .help(groups.map(\.name).joined(separator: ", "))
                            .contextMenu {
                                Button(expanded ? "Stack idle projects" : "Show idle projects") { expandedProjects.toggle() }
                            }
                    }
                }
                .onMove { from, to in store.moveRows(all, from: IndexSet(from.map { $0 + skipped }), to: to + skipped) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // On a rail the limits are on the rail itself.
            if !rail {
                Hairline()
                HStack(alignment: .top, spacing: 0) {
                    UsageView()
                    // The Keep Awake cup, beside the limits while it is on.
                    AwakeIndicator().padding(.top, 6).padding(.trailing, 8)
                }
            }
            }
            .background(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.025)], startPoint: .top, endPoint: .bottom))
            .glassCard()
        }
    }
}

/// A folded group of idle things, "Idle shells" or "Idle projects", with the count in a badge
/// and a chevron. Clicking lists them below; clicking again restacks.
struct StackRow: View {
    let title: String
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 8)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            CountBadge(count: count)
        }
        .font(.system(size: 12))
        .frame(height: 22)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// Transcript modification dates per session, looked up at most every few minutes: the sidebar
/// asks on every redraw.
@MainActor
final class TranscriptDates {
    static let shared = TranscriptDates()
    private var cache: [UUID: (checked: Date, date: Date?)] = [:]

    func date(for tab: TabItem) -> Date? {
        if let hit = cache[tab.id], Date().timeIntervalSince(hit.checked) < 300 { return hit.date }
        let url = Store.claudeTranscriptURL(tab.claudeSessionID.uuidString.lowercased())
        let date = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        cache[tab.id] = (Date(), date)
        return date
    }
}

struct TabRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var pulls = PullRequestMonitor.shared
    @ObservedObject private var diffStats = DiffStatMonitor.shared
    let tab: TabItem
    @State private var pointerOver = false
    @Environment(\.hoverBlocked) private var hoverBlocked
    /// Under the pointer, and nothing lying over the row.
    private var hovering: Bool { pointerOver && !hoverBlocked }
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true
    @AppStorage(Prefs.sidebarDensity) private var density = "comfortable"
    private var compact: Bool { density == "compact" }

    /// "2 agents" while subagents run; the selected session lists them instead.
    private var agentCount: String? {
        guard store.selectedTabID != tab.id else { return nil }
        let running = (monitor.agents[tab.id] ?? []).filter { !$0.finished }.count
        return running > 0 ? "\(running) agent\(running == 1 ? "" : "s")" : nil
    }

    var body: some View { WithRuntime(tab.id) { _ in sessionBody } }

    /// Drawn again whenever this session's live state changes; see `WithRuntime`.
    @ViewBuilder private var sessionBody: some View {
        let rt = store.runtime[tab.id] ?? TabRuntime()
        // Top-aligned so the dot stays beside the name when agent rows or buttons follow.
        HStack(alignment: .top, spacing: 8) {
            // The status dot turns into a close button on hover, as in Safari's tabs.
            ZStack {
                if hovering {
                    Button { store.requestClose(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Close session")
                } else {
                    StatusDot(color: rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.35), pulsing: rt.statusState == .working, size: 8)
                }
            }
            .frame(width: 10, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                if store.renamingID == tab.id {
                    RenameField(initial: tab.name) { store.rename(tab.id, to: $0) }
                } else {
                    HStack(spacing: 5) {
                        Text(tab.name).lineLimit(1).frame(minHeight: 18)
                        if store.layout(near: tab.id)?.contains(tab.id) == true {
                            // On the project's canvas.
                            Image(systemName: "square.grid.2x2").imageScale(.small).foregroundStyle(.tertiary)
                                .help("Shown in a pane")
                        }
                    }
                }
                if compact {
                    // One line a session: the rest is in the tooltip.
                } else if let worktree = tab.worktree {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").imageScale(.small)
                        Text(([worktree.branch, rt.statusLine(showFolder: false), agentCount].compactMap { $0 })
                            .joined(separator: " · "))
                        if let stat = diffStats.stats[tab.id], !stat.isEmpty {
                            Stat(added: stat.added, removed: stat.removed).layoutPriority(1)
                        }
                        if let pr = pulls.requests[tab.id] {
                            PullRequestBadge(pr: pr).layoutPriority(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else if let line = [rt.statusLine(showFolder: showFolderPath), agentCount].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if rt.awaitsPermission {
                    PermissionButtons(tabID: tab.id).padding(.top, 3)
                }
                if pulls.requests[tab.id]?.state == .merged {
                    Button("Delete Worktree") { store.cleanUpMergedWorktree(tab.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("The pull request was merged. Close this session and delete its worktree and branch.")
                        .padding(.top, 3)
                }
                if store.provider(of: tab) == .codex {
                    CodexAgents(tabID: tab.id)
                } else {
                    AgentRows(tabID: tab.id, selected: store.selectedTabID == tab.id)
                }
            }
            Spacer(minLength: 4)
            // Centred on the name line, like the status dot, whatever follows below the name.
            ZStack {
                if hovering {
                    if rt.busy {
                        Button { store.stop(tab.id) } label: { Image(systemName: "stop.fill").font(.system(size: 8)) }
                            .buttonStyle(IconButtonStyle(size: 18))
                            .help("Interrupt (Ctrl-C)")
                    } else if !rt.agentConnected {
                        Button { store.start(tab.id) } label: { Image(systemName: "play.fill").font(.system(size: 8)) }
                            .buttonStyle(IconButtonStyle(size: 18))
                            .help("Start or continue this session")
                    }
                } else if rt.needsAttention {
                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(Palette.needs)
                } else if rt.hasActivity {
                    Circle().fill(Palette.working).frame(width: 6, height: 6)
                }
            }
            .frame(height: 18)
        }
        .buttonStyle(.plain)
        .opacity(rt.exited && !hovering ? 0.55 : 1)
        .padding(.vertical, compact ? 0 : 3)
        .help(compact ? ([tab.worktree?.branch, rt.statusLine(showFolder: true), agentCount].compactMap { $0 }.joined(separator: " · ")) : "")
        .onHover { over in
            pointerOver = over
            if over, !hoverBlocked { store.refreshBusy(tab.id) }
        }
    }
}

struct GroupHeader: View {
    @EnvironmentObject var store: Store
    let group: TabGroup
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if store.renamingID == group.id {
                RenameField(initial: group.name) { store.rename(group.id, to: $0) }
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
            }
            if group.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary).help("Pinned to the top")
            }
            if let host = group.host, group.isRemote { MachineBadge(host: host) }
            Spacer()
            if !hovering { counts }
            // Show/hide chevron on hover, then the + at the trailing edge.
            if group.isCollapsed, !hovering {
                Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary).frame(width: 10)
            }
            if hovering {
                Button { store.updateGroup(group.id) { $0.isCollapsed.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                }
                .help(group.isCollapsed ? "Show sessions" : "Hide sessions")
                Button { store.newTab(in: group.id, command: "") } label: { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                    .help("New shell in \(group.name)")
            }
        }
        .buttonStyle(IconButtonStyle(size: 18))
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // A double click folds the project, as on a Finder sidebar's section.
        .onTapGesture(count: 2) { store.updateGroup(group.id) { $0.isCollapsed.toggle() } }
        .onHover { hovering = $0 }
        .listRowSeparator(.hidden)
        .contextMenu { GroupMenu(group: group) }
    }
}

extension GroupHeader {
    /// How many of the project's sessions are working and how many wait for you, so a glance at
    /// the header is enough; a folded project also says how many sessions it holds.
    @ViewBuilder fileprivate var counts: some View {
        let states = group.tabs.map { store.runtime[$0.id] ?? TabRuntime() }
        let working = states.filter { $0.statusState == .working }.count
        let waiting = states.filter { $0.statusState == .blocked || $0.needsAttention }.count
        let failed = states.filter { $0.statusState == .error }.count
        HStack(spacing: 7) {
            if waiting > 0 { count(waiting, Palette.needs).help("\(waiting) waiting for you") }
            if failed > 0 { count(failed, Palette.error).help("\(failed) stopped with an error") }
            if working > 0 { count(working, Palette.working).help("\(working) working") }
            if group.isCollapsed, waiting + failed + working == 0, !group.tabs.isEmpty {
                Text("\(group.tabs.count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                    .help("\(group.tabs.count) session\(group.tabs.count == 1 ? "" : "s")")
            }
        }
    }

    private func count(_ number: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(number)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Inline rename editor; commits on Enter or focus loss, cancels on Escape.
struct RenameField: View {
    @EnvironmentObject var store: Store
    let initial: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { draft = initial; focused = true }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(save: true) }
            }
    }

    private func finish(save: Bool) {
        guard store.renamingID != nil else { return }
        if save { commit(draft) }
        store.renamingID = nil
    }
}

struct TabMenu: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var pulls = PullRequestMonitor.shared
    let tab: TabItem
    let groupID: UUID

    var body: some View {
        Button("Rename") { store.renamingID = tab.id }
        Button("Edit Session…") { store.editingTabID = tab.id }
        if store.splitIDs.contains(tab.id) {
            Button("Close Pane") { store.removeFromSplit(tab.id) }
        } else if let selected = store.selectedTabID, selected != tab.id {
            Menu("Show in Pane") {
                Button("Right of \(store.tab(selected)?.name ?? "current")") { store.splitPane(selected, with: tab.id, axis: .horizontal) }
                Button("Below \(store.tab(selected)?.name ?? "current")") { store.splitPane(selected, with: tab.id, axis: .vertical) }
            }
        }
        if !store.splitIDs.contains(tab.id) {
            // The way into panes from a single session: a shell beside or below it.
            Button("New Shell to the Right") { store.selectedTabID = tab.id; store.splitWithShell(tab.id, axis: .horizontal) }
            Button("New Shell Below") { store.selectedTabID = tab.id; store.splitWithShell(tab.id, axis: .vertical) }
        }
        Menu("Color") {
            ForEach(TabColor.allCases) { color in
                Button(color.label) { store.updateTab(tab.id) { $0.color = color } }
            }
        }
        if store.groups.count > 1 {
            Menu("Move to") {
                ForEach(store.groups.filter { $0.id != groupID }) { group in
                    Button(group.name) { store.moveTab(tab.id, toGroup: group.id) }
                }
            }
        }
        if let worktree = tab.worktree {
            Divider()
            if let pr = pulls.requests[tab.id], pr.state == .open {
                Button("Open Pull Request #\(pr.number)") { NSWorkspace.shared.open(pr.url) }
                if pr.checksResult == .failed {
                    Button("Send Failing Checks to Session") { store.sendFailingChecks(tab.id) }
                }
            } else if let pr = pulls.requests[tab.id], pr.state == .merged {
                Button("Delete Merged Worktree…") { store.cleanUpMergedWorktree(tab.id) }
                    .help("#\(pr.number) was merged")
            } else {
                Button("Create Pull Request…") { store.createPullRequest(tab.id) }
            }
            Button("Merge into \(worktree.base)") { store.mergeWorktree(tab.id) }
            Button("Open Worktree in Finder") {
                if let dir = store.directory(of: tab) { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
            }
        }
        Divider()
        Button("Interrupt (Ctrl-C)") { store.stop(tab.id) }
        Button("Restart Session") { store.restart(tab.id) }
        Button("Kill Session") { store.kill(tab.id) }
        Button("Close Session", role: .destructive) { store.requestClose(tab.id) }
    }
}

struct GroupMenu: View {
    @EnvironmentObject var store: Store
    let group: TabGroup

    var body: some View {
        Button("New Session") { store.newTab(in: group.id) }
        Button("New Session in Worktree…") { store.newWorktreeGroupID = group.id }
        Button("New Shell") { store.newTab(in: group.id, command: "") }
        Divider()
        Button("Rename") { store.renamingID = group.id }
        Button("Edit Project…") { store.editingGroupID = group.id }
        Divider()
        if group.pinned {
            Button("Unpin") { store.pin(group.id, false) }
        } else {
            Button("Pin to Top") { store.pin(group.id, true) }
        }
        Button("Move Up") { store.moveGroup(group.id, by: -1) }
            .disabled(store.groups.first?.id == group.id)
        Button("Move Down") { store.moveGroup(group.id, by: 1) }
            .disabled(store.groups.last?.id == group.id)
        if group.pinned {
            // Pinned projects never fold into the idle stack.
        } else if group.forcedIdle {
            Button("Move to Active") { store.wake(group.id) }
        } else {
            Button("Move to Idle") { store.updateGroup(group.id) { $0.forcedIdle = true } }
        }
        Divider()
        Button("Delete Project", role: .destructive) { store.deleteGroup(group.id) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
