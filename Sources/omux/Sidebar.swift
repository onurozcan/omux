import SwiftUI
import UniformTypeIdentifiers

/// One row of the flat sidebar list: a project header or a session.
enum SidebarRow: Identifiable, Hashable {
    case group(TabGroup)
    case tab(TabItem, groupID: UUID)

    var id: UUID {
        switch self {
        case .group(let g): return g.id
        case .tab(let t, _): return t.id
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    let theme: Theme

    /// Projects followed by their sessions (hidden while collapsed). A flat list lets
    /// native drag reorder projects and move sessions between them.
    private var rows: [SidebarRow] {
        store.groups.flatMap { group in
            [SidebarRow.group(group)] + (group.isCollapsed ? [] : group.tabs.map { .tab($0, groupID: group.id) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Traffic lights occupy the top-left; actions sit on the right.
            HStack(spacing: 14) {
                Spacer()
                Button { store.newTab() } label: { Image(systemName: "plus") }
                    .help("New session in current project (⌘T)")
                Button { store.openFolderPanel() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Open folder as a project (⌘O)")
                Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Open recent conversation (⇧⌘O)")
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings (⌘,)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 12)
            .frame(height: 28)
            // The list grows into the title bar's safe area when it touches it, which would put it
            // over the buttons and take their clicks. A 1pt gap keeps it below them.
            Spacer(minLength: 0).frame(height: 1)

            List(selection: $store.selectedTabID) {
                ForEach(rows) { row in
                    switch row {
                    case .group(let group):
                        GroupHeader(group: group)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                    case .tab(let tab, let groupID):
                        TabRow(tab: tab)
                            .tag(tab.id)
                            .padding(.leading, 10)
                            .contextMenu { TabMenu(tab: tab, groupID: groupID) }
                    }
                }
                .onMove { from, to in store.moveRows(rows, from: from, to: to) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            UsageView()
        }
        .background(Color(nsColor: theme.chrome))
        .contextMenu {
            // Empty-space menu; rows and project headers override it with their own.
            Button("New Project") { store.newGroup() }
            Button("Open Folder as Project…") { store.openFolderPanel() }
            Button("Open Recent Conversation…") { store.showRecentSessions = true }
            Button("New Codex Session") { store.newTab(command: "codex") }
            Button("New Cursor Session") { store.newTab(command: "cursor-agent") }
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
}

struct TabRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var pulls = PullRequestMonitor.shared
    let tab: TabItem
    @State private var hovering = false
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true

    /// "2 agents" while subagents run; the selected session lists them instead.
    private var agentCount: String? {
        guard store.selectedTabID != tab.id else { return nil }
        let running = (monitor.agents[tab.id] ?? []).filter { !$0.finished }.count
        return running > 0 ? "\(running) agent\(running == 1 ? "" : "s")" : nil
    }

    var body: some View {
        let rt = store.runtime[tab.id] ?? TabRuntime()
        // Top-aligned so the dot stays beside the name when agent rows or buttons follow.
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                if store.renamingID == tab.id {
                    RenameField(initial: tab.name) { store.rename(tab.id, to: $0) }
                } else {
                    Text(tab.name).lineLimit(1)
                }
                if let worktree = tab.worktree {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").imageScale(.small)
                        Text(([worktree.branch, rt.statusLine(showFolder: false), agentCount].compactMap { $0 })
                            .joined(separator: " · "))
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
            if hovering {
                if rt.busy {
                    Button { store.stop(tab.id) } label: { Image(systemName: "stop.fill") }
                        .help("Interrupt (Ctrl-C)")
                } else if !rt.agentConnected {
                    Button { store.start(tab.id) } label: { Image(systemName: "play.fill") }
                        .help("Start or continue this session")
                }
            } else if rt.needsAttention {
                Image(systemName: "bell.fill").font(.caption).foregroundStyle(.orange)
            } else if rt.hasActivity {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
        }
        .buttonStyle(.plain)
        .opacity(rt.exited && !hovering ? 0.55 : 1)
        .padding(.vertical, 2)
        .onHover { over in
            hovering = over
            if over { store.refreshBusy(tab.id) }
        }
    }
}

struct GroupHeader: View {
    @EnvironmentObject var store: Store
    let group: TabGroup
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if store.renamingID == group.id {
                RenameField(initial: group.name) { store.rename(group.id, to: $0) }
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
            // Show/hide chevron on hover, then the + at the trailing edge.
            Button { store.updateGroup(group.id) { $0.isCollapsed.toggle() } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                    .frame(width: 10, height: 10)
            }
            .opacity(hovering || group.isCollapsed ? 1 : 0)
            .help(group.isCollapsed ? "Show sessions" : "Hide sessions")
            Button { store.newTab(in: group.id) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10, height: 10)
            }
            .help("New session in \(group.name)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { GroupMenu(group: group) }
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
        Button("Move Up") { store.moveGroup(group.id, by: -1) }
            .disabled(store.groups.first?.id == group.id)
        Button("Move Down") { store.moveGroup(group.id, by: 1) }
            .disabled(store.groups.last?.id == group.id)
        Divider()
        Button("Delete Project", role: .destructive) { store.deleteGroup(group.id) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
