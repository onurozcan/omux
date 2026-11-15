import SwiftUI

// One compose box for a set of panes. No pane carries a box of its own: the one under them all
// writes to the active pane, and names it.

/// What the shared box needs from a pane's transcript to write to it.
@MainActor
final class PaneCompose: ObservableObject {
    static let shared = PaneCompose()

    struct Route {
        let provider: SessionProvider
        let model: SessionTranscript
        let notice: Binding<String?>
        let send: (String) -> Void
        let queue: (String, Int) -> Void
    }

    @Published private(set) var routes: [UUID: Route] = [:]

    func set(_ route: Route, for id: UUID) { routes[id] = route }
    func remove(_ id: UUID) { routes[id] = nil }
}

/// The box under the panes, addressed to the selected one.
struct PaneComposeBar: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var compose = PaneCompose.shared
    let theme: Theme

    var body: some View {
        if let id = store.selectedTabID, let tab = store.tab(id) {
            if let route = compose.routes[id] {
                ComposeBox(tabID: id, name: tab.name, provider: route.provider, theme: theme, model: route.model,
                           notice: route.notice, send: route.send, addressed: true, onQueue: route.queue)
                    .id(id)
            } else {
                // A pane showing its terminal: what is typed here goes to it as a line.
                TerminalComposeBar(tabID: id, name: tab.name, theme: theme).id(id)
            }
        }
    }
}

/// Who the shared box writes to: the pane's state and name.
struct RecipientChip: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let name: String

    var body: some View {
        WithRuntime(tabID) { _ in
            let runtime = store.runtime[tabID] ?? TabRuntime()
            HStack(spacing: 5) {
                StatusDot(color: runtime.statusColor ?? Color.secondary.opacity(0.5), pulsing: runtime.statusState == .working, size: 6)
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: 180)
            .fixedSize()
            .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("What you write goes to this pane. Click another pane to write to it.")
        }
    }
}

/// The shared box for a pane that shows a terminal: one line, sent to it as typed.
private struct TerminalComposeBar: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let name: String
    let theme: Theme
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            RecipientChip(tabID: tabID, name: name)
            TextField("Type a command for \(name)…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(empty ? Color.secondary : Color.white)
                    .frame(width: 26, height: 26)
                    .background(empty ? Color.primary.opacity(0.08) : Color.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(empty)
        }
        .padding(.leading, 9)
        .padding(.trailing, 9)
        .frame(height: 44)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? Color.accent.opacity(0.55) : .primary.opacity(0.12)))
        .padding(12)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .top) { Hairline() }
    }

    private func submit() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.sendKeys(draft + "\r", to: tabID)
        draft = ""
    }
}
