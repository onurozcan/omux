import SwiftUI

enum PanelTab: String, CaseIterable {
    case files, changes, browser, agents
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
            Text("No agents in this session")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The right panel: Files, Changes, Browser and Agents for the selected session.
struct RightPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var changes = Changes.shared
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var codex = CodexManager.shared
    let root: URL
    let theme: Theme
    @AppStorage(Prefs.panelTab) private var tab = PanelTab.files.rawValue

    private var current: PanelTab { PanelTab(rawValue: tab) ?? .files }

    /// Agents still at work in the selected session, for the tab's badge.
    private var runningAgents: Int {
        guard let id = store.selectedTabID else { return 0 }
        return (monitor.agents[id] ?? []).filter { !$0.finished }.count + (codex.agents[id] ?? []).filter { !$0.finished }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                button(.files, "Files", "doc", shortcut: "1")
                button(.changes, "Changes", "plusminus", shortcut: "2",
                       badge: changes.tabID == store.selectedTabID ? changes.files.count : 0)
                button(.browser, "Browser", "globe", shortcut: "3")
                button(.agents, "Agents", "person.2", shortcut: "4", badge: runningAgents)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(Color(nsColor: theme.chrome))
            // A real hairline rather than an overlay: the split views below extend into any safe
            // area they touch, and the tab bar sits in the title bar's. The hairline keeps them apart.
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)

            ZStack {
                // Files stays alive so its preview and scroll position survive tab switches.
                FilePanel(root: root, theme: theme)
                    .opacity(current == .files ? 1 : 0)
                    .allowsHitTesting(current == .files)
                    .accessibilityHidden(current != .files)
                if current == .changes {
                    ChangesPanel(theme: theme)
                }
                if current == .agents {
                    if let id = store.selectedTabID {
                        AgentsPanel(tabID: id).background(Color(nsColor: theme.chrome))
                    } else {
                        Text("No session").foregroundStyle(.secondary)
                    }
                }
                if current == .browser {
                    if let id = store.selectedTabID {
                        BrowserPanel(session: store.browser(for: id), theme: theme).id(id)
                    } else {
                        Text("No session").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func button(_ value: PanelTab, _ title: String, _ icon: String, shortcut: String, badge: Int = 0) -> some View {
        let selected = current == value
        return Button { tab = value.rawValue } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 14)
                        .background(.primary.opacity(0.14), in: Capsule())
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌥⌘\(shortcut))")
    }
}
