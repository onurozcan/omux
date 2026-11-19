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
    @ObservedObject private var home = HomeState.shared
    @AppStorage(Prefs.homeEnabled) private var homeEnabled = true

    static let width: CGFloat = 46
    /// The tiles' margin: with the gutter after the strip, the same on both sides of a tile.
    static let inset: CGFloat = 11
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
                    if homeEnabled {
                        HomeMark(shown: home.shown, named: open) { home.shown = true; open = false }
                        // A line under it: the projects start below.
                        Hairline().padding(.bottom, 1)
                    }
                    ForEach(active) { group in
                        ProjectMark(group: group, shown: group.id == shownID && !home.shown, named: open) { pick(group) }
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
                            ProjectMark(group: group, shown: group.id == shownID && !home.shown, named: open, quiet: true) { pick(group) }
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
                // As far from the window's edge as from the card beside the strip.
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The limits ride on the rail, so they show whether or not the session list does.
            UsageView(onRail: true, railOpen: open)
                .padding(.leading, Self.inset)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                VStack(spacing: 2) {
                    Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath").font(.system(size: 13.5, weight: .medium)) }
                        .help("Open recent conversation (⇧⌘O)")
                    // Drawn as wide as the limits' ring above them.
                    SettingsLink { Image(systemName: "gearshape").font(.system(size: 13.5, weight: .medium)) }
                        .help("Settings (⌘,)")
                }
                Spacer(minLength: 0)
            }
            // As wide as a tile, on the tiles' own axis.
            .buttonStyle(IconButtonStyle(size: 30))
            .foregroundStyle(.secondary)
            .padding(.leading, Self.inset)
        }
        // Clear of the window's close, minimise and zoom buttons.
        .padding(.top, 34)
        .padding(.bottom, 8)
        .frame(width: open ? Self.openWidth : Self.width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .background(Color(nsColor: theme.chrome))
        // Closed, the strip is the window's own surface and has no edge; open, it lies over the cards.
        .overlay(alignment: .trailing) { if open { Hairline(vertical: true) } }
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, x: 8)
        .contentShape(Rectangle())
        // A click on the strip's own empty space stays here and doesn't reach the list under it.
        .onTapGesture {}
        .onHover { over in
            // A good second's rest opens it: a click on a tile is the quick way, and the names
            // are for when you stop to look.
            hover += 1
            let turn = hover
            if over {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if hover == turn { withAnimation(.easeOut(duration: 0.16)) { open = true } }
                }
            } else {
                // The idle projects fold back with it: they were listed to pick one from.
                withAnimation(.easeOut(duration: 0.14)) { open = false; idleListed = false }
            }
        }
    }
}

/// One project on the rail: a dark tile with a faint sheen, its initials in a colour that is
/// the project's own, and a dot on the corner for the most pressing state among its sessions
/// (waiting, failed, working). The one on show fills softly with its colour and has a bar at
/// the strip's edge.
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
        let state: Color? = waiting > 0 ? Palette.needs : failed > 0 ? Palette.error : working > 0 ? Palette.working : nil
        let hue = Self.hue(group.name)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
          HStack(spacing: 9) {
            tileFace(hue: hue, shape: shape)
                .frame(width: 30, height: 30)
                .background {
                    if shown {
                        shape.fill(hue.opacity(0.22))
                    } else {
                        shape.fill(LinearGradient(colors: [.white.opacity(hovering ? 0.14 : 0.09), .white.opacity(hovering ? 0.06 : 0.03)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay(shape.strokeBorder(shown ? hue.opacity(0.55) : Color.white.opacity(0.09), lineWidth: 1))
                .overlay(alignment: .leading) {
                    // The strip's own edge, eight points to the tile's left.
                    if shown {
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                            .fill(.primary.opacity(0.9))
                            .frame(width: 3, height: 20)
                            .offset(x: -ProjectRail.inset)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let state {
                        StatusDot(color: state, pulsing: waiting == 0 && failed == 0, size: 8)
                            .padding(2)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                            .offset(x: 4, y: -4)
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

    /// The picture the project was given, else its initials.
    @ViewBuilder private func tileFace(hue: Color, shape: RoundedRectangle) -> some View {
        if let picture = ProjectIcons.image(named: group.icon) {
            Image(nsImage: picture).resizable().scaledToFill().clipShape(shape)
        } else {
            Text(Self.initials(group.name)).font(.system(size: 11, weight: .bold)).foregroundStyle(hue)
        }
    }

    /// Six colours a project can have. Which one comes from its name, so it is the same on
    /// every launch and on every Mac.
    private static let hues: [Color] = [
        Color(red: 0.48, green: 0.65, blue: 1.00), Color(red: 0.79, green: 0.55, blue: 0.98), Color(red: 0.37, green: 0.83, blue: 0.60),
        Color(red: 0.96, green: 0.71, blue: 0.38), Color(red: 0.96, green: 0.54, blue: 0.63), Color(red: 0.37, green: 0.82, blue: 0.85),
    ]

    static func hue(_ name: String) -> Color {
        // Not hashValue: that changes with every launch.
        let sum = name.lowercased().unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return hues[Int(sum % UInt32(hues.count))]
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

    private static let lastKey = "railLastSession"
    /// Per project, the session that was on show when the project was last left: kept across
    /// launches, so coming back to a project comes back to where you were in it.
    private var last: [String: String] = UserDefaults.standard.dictionary(forKey: RailState.lastKey) as? [String: String] ?? [:]

    /// The selection moved: its project is the one on show, and it is that project's last session.
    func noteSelection(in store: Store) {
        guard let tab = store.selectedTabID, let group = store.selectedGroup else { return }
        shownGroupID = group.id
        guard last[group.id.uuidString] != tab.uuidString else { return }
        last[group.id.uuidString] = tab.uuidString
        UserDefaults.standard.set(last, forKey: Self.lastKey)
    }

    /// A project picked on the rail: its window, on the session last on show there. Without
    /// one to go back to, the session that waits for you, else the one last worked in.
    func show(_ group: TabGroup, in store: Store) {
        HomeState.shared.shown = false
        shownGroupID = group.id
        guard store.selectedGroup?.id != group.id else { return }
        let remembered = last[group.id.uuidString].flatMap { id in group.tabs.first { $0.id.uuidString == id } }
        let pick = remembered
            ?? group.tabs.first { store.runtime[$0.id]?.statusState == .blocked }
            ?? group.tabs.max { (store.runtime[$0.id]?.lastActivity ?? .distantPast) < (store.runtime[$1.id]?.lastActivity ?? .distantPast) }
        if let pick { store.selectedTabID = pick.id }
    }
}

/// Home's tile, first on the rail: the screen for every project at once. Its dot says a
/// session somewhere waits for you.
struct HomeMark: View {
    @EnvironmentObject var store: Store
    let shown: Bool
    var named = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let waiting = store.allTabs.filter { store.runtime[$0.tab.id]?.statusState == .blocked || store.runtime[$0.tab.id]?.needsAttention == true }.count
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "house.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(shown ? .primary : .secondary)
                    .frame(width: 30, height: 30)
                    // Flat, where the projects' tiles have a sheen: it is a place, not a project.
                    .background(shape.fill(.primary.opacity(shown ? 0.14 : hovering ? 0.07 : 0)))
                if named {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Home").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(waiting > 0 ? "\(waiting) waiting for you" : "Every project at once")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(named ? "" : "Home: what waits for you, what is at work, your to-dos and the week's numbers")
    }
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
                state.show(group, in: store)
                state.open = false
                // A project with no sessions has nothing to put in the tabs: its list opens.
                if group.tabs.isEmpty { reveal() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
