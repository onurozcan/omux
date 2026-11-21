import SwiftUI

// omux's own small kit: the pieces the sidebar, the right panel and the compose box are built
// from, so a header, a badge, a field or an empty panel looks and behaves the same wherever it
// appears. A new panel should be put together from these before it draws anything of its own.
//
//   Hairline          the 1pt rule between two surfaces
//   .panelHeader()    the bar at the top of a panel or a pane of one
//   IconButtonStyle   a glyph button that lights up under the pointer
//   CountBadge        a number in a capsule
//   ChipLabel         a value that opens a menu
//   .fieldBox()       the rounded box around a text field
//   EmptyState        what a panel shows when it has nothing to show
//   RowHighlight      a row's selected and hovered background
//   SoftRow           a list row that selects on a click and draws that highlight
//   PromptButtonStyle the buttons on a card that asks something
//   .actsAsTitleBar() a top strip that drags the window and fills the screen, as a title bar would

/// A toolbar glyph that lights up under the pointer and dims when it can't be used.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .frame(width: size, height: size)
            .background(.primary.opacity(configuration.isPressed ? 0.16 : hovering && enabled ? 0.09 : 0),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A capsule the compose box uses for what the next turn runs with: a glyph, the value, and a
/// chevron that says it opens a menu.
struct ChipLabel: View {
    let text: String
    var icon: String?
    var logo: NSImage?

    var body: some View {
        HStack(spacing: 5) {
            if let logo {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().frame(width: 11, height: 11)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.primary.opacity(0.07), in: Capsule())
        .contentShape(Capsule())
    }
}

/// The background of a session's row in the sidebar: a quiet rounded fill when it is selected
/// or under the pointer, in place of the system's solid selection bar.
struct RowHighlight: View {
    let selected: Bool
    var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.primary.opacity(selected ? 0.11 : hovering ? 0.05 : 0))
            .padding(.horizontal, 6)
    }
}

/// The 1pt rule between two surfaces.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

extension View {
    /// The bar at the top of a panel, or of one pane inside it: a title on the left, glyph
    /// buttons on the right, a hairline under it.
    func panelHeader(height: CGFloat = 30) -> some View {
        self
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: height)
            .overlay(alignment: .bottom) { Hairline() }
    }

    /// The rounded box around a text field and what sits inside it.
    func fieldBox(height: CGFloat = 24) -> some View {
        self
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// For a strip along the window's top. The window has no title bar of its own to click, so
    /// the strip's empty space does what one would: drag the window, and on a double-click fill
    /// the screen or minimize it. Buttons and tabs on the strip keep their clicks.
    func actsAsTitleBar() -> some View { background(TitleBarArea()) }
}

private struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {}

    final class AreaView: NSView {
        /// Where the window was before a double-click filled its screen, to go back to on the next.
        private static var unfilledFrame: NSRect?

        // The click is handled below, so AppKit shouldn't start a drag of its own as well.
        override var mouseDownCanMoveWindow: Bool { false }
        // A title bar drags a window that isn't in front, too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            // In full screen there's nothing to fill or minimize.
            guard !window.styleMask.contains(.fullScreen) else { return }
            // What the person picked in System Settings, Desktop & Dock. Older systems kept only
            // a yes or no for minimizing; with neither set, a double-click fills the screen.
            let defaults = UserDefaults.standard
            switch defaults.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None", "Do Nothing": break
            case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"): window.performMiniaturize(nil)
            default: Self.toggleFill(window)
            }
        }

        /// Fills the screen the window is on, or puts it back where it was. Not performZoom: the
        /// window's SwiftUI delegate picks the zoomed frame itself (windowWillUseStandardFrame),
        /// so it isn't certain to be the whole screen.
        private static func toggleFill(_ window: NSWindow) {
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            if window.frame == visible, let frame = unfilledFrame {
                unfilledFrame = nil
                window.setFrame(frame, display: true, animate: true)
            } else {
                unfilledFrame = window.frame
                window.setFrame(visible, display: true, animate: true)
            }
        }
    }
}

/// A number in a capsule: changed files, running agents, stacked sessions.
struct CountBadge: View {
    let count: Int
    /// Stronger on a selected or important surface.
    var strong = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 15)
            .background(.primary.opacity(strong ? 0.14 : 0.1), in: Capsule())
    }
}

/// What a panel shows when it has nothing to show: a glyph, what is missing, and what to do
/// about it. Anything passed as content (a button, a list of links) goes under the text.
struct EmptyState<Content: View>: View {
    var icon: String?
    let title: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 3)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Content == EmptyView {
    init(icon: String? = nil, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// A row of a list that selects on a click and draws its own highlight. The list it sits in
/// has no selection binding, so the system's solid bar never shows; the list moves the
/// selection for the arrow keys itself.
private struct HoverBlockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Something lies over these rows: the pointer above it is not on them, whatever the
    /// system's hover tracking says. Blocking clicks alone leaves hover going through.
    var hoverBlocked: Bool {
        get { self[HoverBlockedKey.self] }
        set { self[HoverBlockedKey.self] = newValue }
    }
}

struct SoftRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    @Environment(\.hoverBlocked) private var blocked

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .listRowSeparator(.hidden)
            .listRowBackground(RowHighlight(selected: selected, hovering: hovering && !blocked))
    }
}

/// The buttons on a prompt's card: the answer the card leads with is filled, the others are
/// quiet, and the way out is plain text.
struct PromptButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary

    init(_ kind: Kind = .secondary) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        PromptButtonBody(configuration: configuration, kind: kind)
    }
}

private struct PromptButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: PromptButtonStyle.Kind
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : kind == .ghost ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(.primary.opacity(hovering ? 1 : 0.92))
        case .secondary: AnyShapeStyle(.primary.opacity(hovering ? 0.15 : 0.09))
        case .ghost: AnyShapeStyle(.primary.opacity(hovering ? 0.08 : 0))
        }
    }
}
