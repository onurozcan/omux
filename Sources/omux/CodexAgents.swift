import SwiftUI

struct CodexAgents: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var manager = CodexManager.shared
    let tabID: UUID
    var compact = false
    @State private var open = false

    private var agents: [CodexAgent] { manager.agents[tabID] ?? [] }

    var body: some View {
        if !agents.isEmpty {
            if compact {
                Button { open.toggle() } label: {
                    Label("\(agents.filter { !$0.finished }.count) agents", systemImage: "person.2")
                }
                .popover(isPresented: $open) { rows.padding(10).frame(width: 320) }
            } else { rows }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(agents) { agent in
                Button {
                    store.openAgent = nil
                    store.openCodexAgent = CodexAgentRef(tabID: tabID, agent: agent)
                    store.showPanel(.agents)
                    open = false
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(agent.finished ? Palette.done : Palette.working).frame(width: 6, height: 6)
                        Text(agent.name).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(agent.state).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
    }
}

struct CodexAgentTranscriptView: View {
    @EnvironmentObject var store: Store
    let ref: CodexAgentRef
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(ref.agent.name).lineLimit(1)
                Text("Recent activity · up to 100 items").foregroundStyle(.secondary)
                Spacer()
                Button { store.openCodexAgent = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(10)
            Divider()
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding()
            } else if text.isEmpty {
                Text("Waiting for the agent's transcript…").font(.caption).foregroundStyle(.secondary).padding()
            } else { MarkdownView(text: text) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                do {
                    let result = try await CodexManager.shared.transcript(threadID: ref.agent.id, tabID: ref.tabID)
                    guard !Task.isCancelled else { return }
                    text = result; error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
