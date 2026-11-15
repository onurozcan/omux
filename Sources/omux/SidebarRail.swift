import SwiftUI

// The rail layout of the sidebar: every project is a mark on a narrow strip, and the list
// beside it shows the sessions of the one picked. However many projects there are, each is one
// click away and the list stays short.

/// The strip of project marks, with the app's own buttons at its foot.
struct ProjectRail: View {
    @EnvironmentObject var store: Store
    let shownID: UUID?
    let theme: Theme
    /// Open while the pointer rests on the strip: every project by name, over the list. The
    /// sidebar holds it, so the list underneath can stop taking clicks meanwhile.
    @Binding var open: Bool
    let pick: (TabGroup) -> Void
    @State private var hover = 0
    /// The idle projects are listed under their stack instead of folded into it.
    @State private var idleListed = false

    static let width: CGFloat = 46
    static let openWidth: CGFloat = 196

    /// Pinned and active projects, in the sidebar's own order.
    private var active: [TabGroup] {
        let working = store.groups.filter { store.isActive($0) }
        return working.filter(\.pinned) + working.filter { !$0.pinned }
    }

    /// Projects with nothing going on, most recently used first. Two or more fold into one tile,
    /// as they fold into one row in the list layout.
    private var idle: [TabGroup] {
        store.groups.filter { !store.isActive($0) }.sorted { store.lastActivity($0) > store.lastActivity($1) }
    }

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(active) { group in
                        ProjectMark(group: group, shown: group.id == shownID, named: open) { pick(group) }
                            .contextMenu { GroupMenu(group: group) }
                    }
                    let idle = idle
                    // The project on show stays in view, so a stack holding it lists itself.
                    let listed = idle.count < 2 || idleListed || idle.contains { $0.id == shownID }
                    if idle.count >= 2 {
                        Button { idleListed.toggle() } label: {
                            HStack(spacing: 9) {
                                Text("+\(idle.count)")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                if open {
                                    Text("Idle projects").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(listed ? 90 : 0))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(idle.map(\.name).joined(separator: ", "))
                    }
                    if listed {
                        ForEach(idle) { group in
                            ProjectMark(group: group, shown: group.id == shownID, named: open, quiet: true) { pick(group) }
                                .contextMenu { GroupMenu(group: group) }
                        }
                    }
                    Button { store.openFolderPanel() } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            if open { Text("Open a folder…").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1); Spacer(minLength: 0) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open folder as a project (⌘O)")
                    .contextMenu {
                        Button("New Project") { store.newGroup() }
                        Button("New Remote Project…") { store.showRemoteProject = true }
                        Button("Open Folder as Project…") { store.openFolderPanel() }
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The limits ride on the rail, so they show whether or not the session list does.
            UsageView(onRail: true, railOpen: open)
                .padding(.leading, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                VStack(spacing: 2) {
                    Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("Open recent conversation (⇧⌘O)")
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
        }
        // Clear of the window's close, minimise and zoom buttons.
        .padding(.top, 34)
        .padding(.bottom, 8)
        .frame(width: open ? Self.openWidth : Self.width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, x: 8)
        .contentShape(Rectangle())
        // A click on the strip's own empty space stays here and doesn't reach the list under it.
        .onTapGesture {}
        .onHover { over in
            // A moment's rest opens it, so crossing the strip on the way elsewhere doesn't.
            hover += 1
            let turn = hover
            if over {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if hover == turn { withAnimation(.easeOut(duration: 0.16)) { open = true } }
                }
            } else {
                withAnimation(.easeOut(duration: 0.14)) { open = false }
            }
        }
    }
}

/// One project on the rail: its initials on a tile in the colour of the most pressing state
/// among its sessions (waiting, failed, working), grey when nothing is going on. A bar at the
/// strip's edge marks the one on show.
private struct ProjectMark: View {
    @EnvironmentObject var store: Store
    let group: TabGroup
    let shown: Bool
    /// The rail is open: the name and what its sessions are doing go beside the mark.
    var named = false
    /// An idle project, listed under the stack: fainter than the ones with work in them.
    var quiet = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let states = group.tabs.map { store.runtime[$0.id] ?? TabRuntime() }
        let waiting = states.filter { $0.statusState == .blocked || $0.needsAttention }.count
        let failed = states.filter { $0.statusState == .error }.count
        let working = states.filter { $0.statusState == .working }.count
        let tint: Color? = waiting > 0 ? Palette.needs : failed > 0 ? Palette.error : working > 0 ? Palette.working : nil
        Button(action: action) {
          HStack(spacing: 9) {
            Text(Self.initials(group.name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? (shown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(width: 30, height: 30)
                .background(tint.map { AnyShapeStyle($0.opacity(shown || hovering ? 0.3 : 0.2)) } ?? AnyShapeStyle(.primary.opacity(shown ? 0.18 : hovering ? 0.14 : 0.08)),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .leading) {
                    // The strip's own edge, eight points to the tile's left.
                    if shown {
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                            .fill(.primary.opacity(0.9))
                            .frame(width: 3, height: 20)
                            .offset(x: -8)
                    }
                }
                .opacity(quiet && !shown && !hovering ? 0.55 : 1)
            if named {
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(Self.doing(sessions: group.tabs.count, waiting: waiting, failed: failed, working: working))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Open, the strip says all this itself.
        .help(named ? "" : Self.summary(group.name, sessions: group.tabs.count, waiting: waiting, failed: failed, working: working))
    }

    /// "acme-web" → "AW", "infra" → "IN", "My Project" → "MP".
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { !$0.isEmpty }
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        return letters.isEmpty ? "·" : letters.uppercased()
    }

    /// "1 waiting · 1 failed", or the number of sessions when nothing is going on.
    static func doing(sessions: Int, waiting: Int, failed: Int, working: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) failed") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? "\(sessions) session\(sessions == 1 ? "" : "s")" : parts.joined(separator: " · ")
    }

    static func summary(_ name: String, sessions: Int, waiting: Int, failed: Int, working: Int) -> String {
        var parts = ["\(sessions) session\(sessions == 1 ? "" : "s")"]
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if failed > 0 { parts.append("\(failed) stopped with an error") }
        if working > 0 { parts.append("\(working) working") }
        return name + " · " + parts.joined(separator: ", ")
    }
}

/// The name of the project the list shows, with where it is, above its sessions.
struct RailProjectTitle: View {
    @EnvironmentObject var store: Store
    let group: TabGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if store.renamingID == group.id {
                    RenameField(initial: group.name) { store.rename(group.id, to: $0) }
                } else {
                    Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                if group.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary).help("Pinned to the top")
                }
                if let host = group.host, group.isRemote { MachineBadge(host: host) }
            }
            if let directory = group.directory, !directory.isEmpty {
                Text(directory.tildeAbbreviated)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .contextMenu { GroupMenu(group: group) }
    }
}

/// What the rail shows and whether it is open. Shared, because the rail has two homes: beside
/// the session list in the sidebar, and on its own at the window's edge when the list is closed.
@MainActor
final class RailState: ObservableObject {
    static let shared = RailState()
    /// The project the list shows. It follows the selected session, and a click on the strip
    /// moves it, also to a project with no sessions to select.
    @Published var shownGroupID: UUID?
    /// Open under the pointer, lying over what is beside it.
    @Published var open = false
}

/// The rail by itself, for when the session list is closed: the strip stays at the window's
/// edge, and a click on a project brings the list back with that project in it.
struct StandaloneRail: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var state = RailState.shared
    let theme: Theme
    let reveal: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if state.open {
                // Whatever misses the strip lands here, not on the session behind it.
                Color.black.opacity(0.001).onTapGesture { state.open = false }
            }
            ProjectRail(shownID: state.shownGroupID ?? store.selectedGroup?.id, theme: theme, open: $state.open) { group in
                state.shownGroupID = group.id
                state.open = false
                reveal()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
