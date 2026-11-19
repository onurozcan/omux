import SwiftUI
import OmuxCore

/// What the agents have to work with on this Mac: MCP servers, plugins, skills, subagents,
/// commands and hooks, as their own files list them. The same reading /mcp and the others
/// show inside a conversation, here for every project at once.
struct HomeSetup: Sendable {
    struct Item: Sendable, Identifiable {
        let id: Int
        let name: String
        let detail: String
        let note: String
        let off: Bool
    }
    struct Section: Sendable, Identifiable {
        let kind: String
        let title: String
        let items: [Item]
        var id: String { kind }
    }
    var claude: [Section]
    /// Nil when Codex isn't set up on this Mac.
    var codex: [Section]?

    private static let kinds = [("mcp", "MCP"), ("plugins", "Plugins"), ("skills", "Skills"), ("agents", "Agents"), ("commands", "Commands"), ("hooks", "Hooks")]

    static func read() -> HomeSetup {
        // No project: what is set up for the user, and so there in every session.
        func sections(_ provider: SessionProvider) -> [Section] {
            kinds.compactMap { kind, title in
                guard let overview = AgentConfig.overview(for: kind, project: "", provider: provider) else { return nil }
                let items = overview.rows.enumerated().map { Item(id: $0.offset, name: $0.element.name, detail: $0.element.detail, note: $0.element.note, off: $0.element.state == "off") }
                return Section(kind: kind, title: title, items: items)
            }
        }
        let hasCodex = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex")
        return HomeSetup(claude: sections(.claude), codex: hasCodex ? sections(.codex).filter { !$0.items.isEmpty } : nil)
    }
}

struct HomeSetupCard: View {
    let setup: HomeSetup
    @AppStorage("homeSetupKind") private var kind = "mcp"
    @AppStorage("homeSetupCodex") private var codex = false
    @State private var query = ""

    private var showsCodex: Bool { codex && !(setup.codex ?? []).isEmpty }
    private var sections: [HomeSetup.Section] { showsCodex ? setup.codex ?? [] : setup.claude }
    private var section: HomeSetup.Section? { sections.first { $0.kind == kind } ?? sections.first }
    private var items: [HomeSetup.Item] {
        let all = section?.items ?? []
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.detail.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(sections) { section in
                    let chosen = section.kind == self.section?.kind
                    Button { kind = section.kind } label: {
                        HStack(spacing: 5) {
                            Text(section.title).font(.system(size: 11.5, weight: chosen ? .semibold : .regular))
                            Text("\(section.items.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(.primary.opacity(chosen ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 6)
                if !(setup.codex ?? []).isEmpty {
                    ForEach([false, true], id: \.self) { isCodex in
                        Button { codex = isCodex } label: {
                            ProviderLogo(provider: isCodex ? .codex : .claude, size: 12)
                                .foregroundStyle(showsCodex == isCodex ? .primary : .tertiary)
                                .frame(width: 24, height: 22)
                                .background(.primary.opacity(showsCodex == isCodex ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isCodex ? "What Codex has" : "What Claude Code has")
                    }
                }
            }
            if (section?.items.count ?? 0) > 8 {
                TextField("Filter", text: $query).textFieldStyle(.plain).font(.system(size: 11.5))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if items.isEmpty {
                Text(query.isEmpty ? "None set up." : "Nothing matches.").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(item.off ? Color.primary.opacity(0.2) : Palette.done).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                                Text(item.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).layoutPriority(1)
                                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 6)
                                Text(item.note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .padding(.vertical, 4)
                            .opacity(item.off ? 0.55 : 1)
                            .help(item.detail.isEmpty ? item.name : item.name + "\n" + item.detail)
                        }
                    }
                }
                .frame(maxHeight: 236)
            }
            Text("Set up for you, so there in every session. A project's own show under /mcp, /skills and the others in its conversation, where they can be changed too.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
