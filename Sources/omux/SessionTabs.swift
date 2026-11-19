import SwiftUI

// With the session list closed, a project's sessions are tabs in the window's header: agents
// on the left, the open one wide enough to say what it is doing, and shells apart on the right.

struct SessionTabs: View {
    @EnvironmentObject var store: Store
    let group: TabGroup

    private var agents: [TabItem] { group.tabs.filter { store.provider(of: $0) != .shell } }
    private var shells: [TabItem] { group.tabs.filter { store.provider(of: $0) == .shell } }

    /// The tab the row is scrolled to, counted from the left; arrows and the wheel move it.
    @State private var lead = 0
    @State private var contentWidth: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    @State private var hovering = false
    @State private var wheel: Any?
    /// Wheel travel not yet spent on a step.
    @State private var travel: CGFloat = 0

    private var overflows: Bool { contentWidth > rowWidth + 1 }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                HStack(spacing: 2) {
                    // More tabs than fit: arrows step through them, as well as a sideways swipe.
                    if overflows {
                        Button { step(-1, proxy) } label: { Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(IconButtonStyle(size: 18))
                            .foregroundStyle(.secondary)
                            .disabled(lead == 0)
                            .help("Earlier sessions")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(agents) { tab in
                                SessionTab(tab: tab, groupID: group.id, open: tab.id == store.selectedTabID).id(tab.id)
                            }
                            Button { store.newTab(in: group.id) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                                .buttonStyle(IconButtonStyle(size: 22))
                                .foregroundStyle(.secondary)
                                .help("New session in \(group.name)")
                        }
                        .background(GeometryReader { geo in
                            Color.clear.onAppear { contentWidth = geo.size.width }.onChange(of: geo.size.width) { _, width in contentWidth = width }
                        })
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { rowWidth = geo.size.width }.onChange(of: geo.size.width) { _, width in rowWidth = width }
                    })
                    if overflows {
                        Button { step(1, proxy) } label: { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(IconButtonStyle(size: 18))
                            .foregroundStyle(.secondary)
                            .disabled(lead >= agents.count - 1)
                            .help("Later sessions")
                    }
                }
                .onHover { hovering = $0 }
                .onChange(of: store.selectedTabID) { _, id in
                    guard let id, let index = agents.firstIndex(where: { $0.id == id }) else { return }
                    lead = index
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear {
                    // A mouse wheel only turns one way. Over the tabs, up and down move them
                    // sideways; a sideways swipe is left to the row itself.
                    wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        guard hovering, overflows, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                        travel += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
                        if abs(travel) >= 24 {
                            step(travel < 0 ? 1 : -1, proxy)
                            travel = 0
                        }
                        return nil
                    }
                }
                .onDisappear {
                    if let wheel { NSEvent.removeMonitor(wheel) }
                    wheel = nil
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !shells.isEmpty {
                Hairline(vertical: true).frame(height: 16)
                HStack(spacing: 3) {
                    ForEach(shells) { tab in
                        ShellChip(tab: tab, groupID: group.id, open: tab.id == store.selectedTabID)
                    }
                }
            }
        }
    }

    private func step(_ by: Int, _ proxy: ScrollViewProxy) {
        guard !agents.isEmpty else { return }
        lead = min(max(lead + by, 0), agents.count - 1)
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(agents[lead].id, anchor: .leading) }
    }
}

/// An agent's tab: its state and name, and for the open one what it is doing and a way to close it.
private struct SessionTab: View {
    @EnvironmentObject var store: Store
    let tab: TabItem
    let groupID: UUID
    let open: Bool
    @State private var hovering = false

    var body: some View {
        WithRuntime(tab.id) { _ in
            let runtime = store.runtime[tab.id] ?? TabRuntime()
            // Waiting for an answer: the tab blinks slowly until it gets one, open or not.
            let waiting = runtime.statusState == .blocked || runtime.needsAttention
            HStack(spacing: 6) {
                StatusDot(color: runtime.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.4), pulsing: runtime.statusState == .working, size: 7)
                Text(tab.name)
                    .font(.system(size: 11, weight: open ? .semibold : .medium))
                    .foregroundStyle(open || waiting ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: open ? 220 : 120, alignment: .leading)
                    .fixedSize()
                if open, let line = runtime.statusLine(showFolder: false) {
                    Text("· " + line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                        .fixedSize()
                }
                if open, hovering {
                    Button { store.requestClose(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                        .buttonStyle(IconButtonStyle(size: 16))
                        .foregroundStyle(.secondary)
                        .help("Close session")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(.primary.opacity(open ? 0.13 : hovering ? 0.06 : 0), in: Capsule())
            .background {
                // Drawn by Core Animation, so the blink costs the app nothing while it runs.
                if waiting { BreathingDot(color: Palette.needs.opacity(0.42), pulsing: true, slow: true) }
            }
            .contentShape(Capsule())
            .onTapGesture { store.selectedTabID = tab.id }
            .onHover { hovering = $0 }
            .help(open ? "" : [tab.name, waiting ? "waiting for you" : nil, runtime.statusLine(showFolder: false)].compactMap { $0 }.joined(separator: " · "))
            .contextMenu { TabMenu(tab: tab, groupID: groupID) }
        }
    }
}

/// A shell, apart from the agents: a small chip with a prompt mark.
private struct ShellChip: View {
    @EnvironmentObject var store: Store
    let tab: TabItem
    let groupID: UUID
    let open: Bool
    @State private var hovering = false

    var body: some View {
        WithRuntime(tab.id) { _ in
            let runtime = store.runtime[tab.id] ?? TabRuntime()
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(runtime.busy ? AnyShapeStyle(Palette.working) : AnyShapeStyle(.tertiary))
                Text(tab.name)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(open ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .leading)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.primary.opacity(open ? 0.14 : hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { store.selectedTabID = tab.id }
            .onHover { hovering = $0 }
            .help(runtime.busy ? "\(tab.name) · running" : tab.name)
            .contextMenu { TabMenu(tab: tab, groupID: groupID) }
        }
    }
}
