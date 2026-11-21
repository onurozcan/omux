import SwiftUI

enum PanelTab: String, CaseIterable {
    case files, changes, browser, agents
}

/// The agents still at work in a session. A view of its own, so the agent monitors redraw this
/// number and not the whole panel.
struct RunningAgentsBadge: View {
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var codex = CodexManager.shared
    let tabID: UUID

    var body: some View {
        let running = (monitor.agents[tabID] ?? []).filter { !$0.finished }.count + (codex.agents[tabID] ?? []).filter { !$0.finished }.count
        if running > 0 { CountBadge(count: running, strong: true) }
    }
}

/// The Agents tab: the session's subagents, and the transcript of the one picked.
struct AgentsPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var codex = CodexManager.shared
    let tabID: UUID

    var body: some View {
        if let agent = store.openAgent, agent.tabID == tabID {
            AgentTranscriptView(ref: agent).id(agent.agentID)
        } else if let ref = store.openCodexAgent, ref.tabID == tabID {
            CodexAgentTranscriptView(ref: ref).id(ref.agent.id)
        } else if !(monitor.agents[tabID] ?? []).isEmpty {
            ScrollView { AgentList(tabID: tabID, inPanel: true) {} }
        } else if !(codex.agents[tabID] ?? []).isEmpty {
            ScrollView { CodexAgents(tabID: tabID).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            EmptyState(icon: "person.2", title: "No agents in this session", detail: "Subagents the session starts are listed here, each with its own transcript.")
        }
    }
}

/// The right panel: Files, Changes, Browser and Agents for the selected session.
struct RightPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var changes = Changes.shared
    let root: URL
    let theme: Theme
    @AppStorage(Prefs.panelTab) private var tab = PanelTab.files.rawValue

    private var current: PanelTab { PanelTab(rawValue: tab) ?? .files }

    var body: some View {
        VStack(spacing: 0) {
            // Every tab named when there is room; in a narrow panel only the one that is open.
            ViewThatFits(in: .horizontal) {
                tabs(titles: true)
                tabs(titles: false)
            }
            // The session header carried on across the panel: the same height, the same surface,
            // and tabs drawn as the header draws its sessions.
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .actsAsTitleBar()
            // A real gap rather than nothing: the split views below extend into any safe area
            // they touch, and the tab bar sits in the title bar's. The point keeps them apart.
            Color.clear.frame(height: 1)

            Group {
            if let group = store.selectedGroup, group.isRemote, let host = group.host, current == .files {
                // The folder is on another machine: listed there, and files copied here to be shown.
                let folder = store.selectedTab?.directory ?? group.directory ?? "~"
                RemoteFilePanel(host: host, folder: folder, theme: theme).id(host + "\n" + folder)
            } else {
            ZStack {
                // Files stays alive so its preview and scroll position survive tab switches.
                FilePanel(root: root, theme: theme, visible: current == .files)
                    .opacity(current == .files ? 1 : 0)
                    .allowsHitTesting(current == .files)
                    .accessibilityHidden(current != .files)
                if current == .changes {
                    ChangesPanel(theme: theme)
                }
                if current == .agents {
                    if let id = store.selectedTabID {
                        AgentsPanel(tabID: id).background(Color(nsColor: theme.background))
                    } else {
                        EmptyState(title: "No session")
                    }
                }
                if current == .browser {
                    if let id = store.selectedTabID {
                        BrowserPanel(session: store.browser(for: id), theme: theme).id(id)
                    } else {
                        EmptyState(title: "No session")
                    }
                }
            }
            }
            }
            // One surface for every tab, the session's own.
            .background(Color(nsColor: theme.background))
            .glassCard()
        }

    }

    private func tabs(titles: Bool) -> some View {
        HStack(spacing: 2) {
            button(.files, "Files", "folder", shortcut: "1", titled: titles)
            button(.changes, "Changes", "plusminus", shortcut: "2",
                   badge: changes.tabID == store.selectedTabID ? changes.files.count : 0, titled: titles)
            button(.browser, "Browser", "globe", shortcut: "3", titled: titles)
            button(.agents, "Agents", "person.2", shortcut: "4", agentsOf: store.selectedTabID, titled: titles)
        }
    }

    private func button(_ value: PanelTab, _ title: String, _ icon: String, shortcut: String, badge: Int = 0, agentsOf: UUID? = nil, titled: Bool = true) -> some View {
        let selected = current == value
        return Button { tab = value.rawValue } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                if titled || selected { Text(title).fixedSize() }
                if badge > 0 { CountBadge(count: badge, strong: true) }
                if let agentsOf { RunningAgentsBadge(tabID: agentsOf) }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .foregroundStyle(selected ? .primary : .secondary)
            .frame(height: 22)
            .background(selected ? Color.primary.opacity(0.13) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌥⌘\(shortcut))")
    }
}
