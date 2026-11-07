import AppKit
import Combine

/// What the edge light shows: green while an agent works, yellow while a session waits,
/// red when no session is running. Green and yellow can be lit together.
struct EdgeLightState: Equatable {
    var working = false
    var waiting = false
    var idle = true

    /// Derived from the store's live sessions; exited ones don't count.
    @MainActor static func current() -> EdgeLightState {
        let store = Store.shared
        let live = store.runtime.values.filter { !$0.exited }
        let working = live.contains { $0.statusState == .working }
        // needsAttention is the app's own "waits for you", what the Dock badge counts: it clears
        // once the session is looked at, which a raw .done or .blocked state wouldn't.
        let waiting = live.contains(where: \.needsAttention)
        return EdgeLightState(working: working, waiting: waiting, idle: store.runningSessionCount == 0)
    }
}

/// A small always-on-top traffic light glued to a screen edge (Settings › Notifications › Status Light).
/// Off by default; the panel only exists while the setting is on.
@MainActor
final class EdgeLight: NSObject {
    static let shared = EdgeLight()

    enum Side: String { case left, right }

    private static let normalSize = NSSize(width: 18, height: 92)
    private static let compactSize = NSSize(width: 18, height: 44)

    private var panel: NSPanel?
    private var view: EdgeLightView?
    private var storeObserver: AnyCancellable?
    private var refreshQueued = false

    private var side: Side {
        get { Side(rawValue: UserDefaults.standard.string(forKey: Prefs.edgeLightSide) ?? "") ?? .right }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Prefs.edgeLightSide) }
    }

    private var compact: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.edgeLightCompact) }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.edgeLightCompact) }
    }

    /// Shows the panel if the setting is on. Settings calls `sync()` when the setting changes.
    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        sync()
    }

    /// Shows or closes the panel to match the setting.
    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Prefs.edgeLight)
        if enabled, panel == nil { show() } else if !enabled, panel != nil { hide() }
    }

    private func show() {
        let size = compact ? Self.compactSize : Self.normalSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // After isFloatingPanel, which resets the level to .floating.
        panel.level = .statusBar
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false

        let view = EdgeLightView(frame: NSRect(origin: .zero, size: size))
        view.side = side
        view.compact = compact
        view.controller = self
        view.state = .current()
        panel.contentView = view
        self.panel = panel
        self.view = view

        let savedY = UserDefaults.standard.object(forKey: Prefs.edgeLightY) as? Double
        let midY = screen?.visibleFrame.midY ?? 0
        place(y: savedY.map { CGFloat($0) } ?? (midY - size.height / 2))
        panel.orderFrontRegardless()

        storeObserver = Store.shared.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }
    }

    private func hide() {
        storeObserver = nil
        panel?.close()
        panel = nil
        view = nil
    }

    /// objectWillChange fires before the change lands, so the state is read on the next turn;
    /// a burst of changes costs one read.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshQueued = false
            view?.state = .current()
        }
    }

    /// The panel's screen once it's shown; before that the one with the key window, so the
    /// light opens where the user is rather than on the primary display. nil for the moment a
    /// closed-lid MacBook has no display at all, as when its external one is unplugged.
    private var screen: NSScreen? {
        (panel?.isVisible == true ? panel?.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Glues the panel to the chosen edge and keeps its vertical position on screen. With no
    /// screen the light stays where it was; the next screen change places it again.
    func place(y: CGFloat) {
        guard let panel, let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = side == .right ? vf.maxX - size.width : vf.minX
        let clampedY = min(max(y, vf.minY), vf.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    func saveY() {
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Prefs.edgeLightY)
    }

    func bringOmuxForward() {
        AppDelegate.showMainWindow()
        NSApp.activate()
    }

    private func setSide(_ s: Side) {
        side = s
        view?.side = s
        if let panel { place(y: panel.frame.origin.y) }
    }

    @objc func snapLeft() { setSide(.left) }
    @objc func snapRight() { setSide(.right) }

    @objc func toggleCompact() {
        guard let panel else { return }
        compact.toggle()
        view?.compact = compact
        let midY = panel.frame.midY
        let size = compact ? Self.compactSize : Self.normalSize
        panel.setContentSize(size)
        place(y: midY - size.height / 2)
        saveY()
    }

    /// Turns the setting off, which is what the Settings toggle shows next time.
    @objc func hideFromMenu() {
        UserDefaults.standard.set(false, forKey: Prefs.edgeLight)
        hide()
    }

    @objc private func screenChanged() {
        if let panel { place(y: panel.frame.origin.y) }
    }
}

/// Draws the black flare and its three lights; handles click, drag and the context menu.
final class EdgeLightView: NSView {
    var state = EdgeLightState() {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(Self.label(for: state))
        }
    }
    var side: EdgeLight.Side = .right { didSet { needsDisplay = true } }
    var compact = false { didSet { needsDisplay = true } }
    weak var controller: EdgeLight?

    private static let green = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.35, alpha: 1)
    private static let yellow = NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.15, alpha: 1)
    private static let red = NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1)
    private static let dotSize: CGFloat = 7
    private static let dotGap: CGFloat = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.label(for: state))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What VoiceOver reads, since the lights are colour only.
    private static func label(for state: EdgeLightState) -> String {
        var parts: [String] = []
        if state.working { parts.append("agent working") }
        if state.waiting { parts.append("session waiting for you") }
        if state.idle { parts.append("no session running") }
        return "omux status: " + (parts.isEmpty ? "sessions idle" : parts.joined(separator: ", "))
    }

    /// The first click counts even while omux isn't the active app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// VoiceOver's press is the click: the mouse path lives in mouseDown's tracking loop.
    override func accessibilityPerformPress() -> Bool {
        guard let c = controller else { return false }
        c.bringOmuxForward()
        return true
    }

    /// VoiceOver's "show menu" is the right-click.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenu() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Deliberately black regardless of theme, like the notch it imitates.
        NSColor.black.setFill()
        bodyPath().fill()
        drawLights()
    }

    /// A bump that flares out of the edge, flat in the middle, tapering back at both ends.
    /// Drawn for the right edge; mirrored on x for the left edge.
    private func bodyPath() -> NSBezierPath {
        let r = bounds
        let flare: CGFloat = compact ? 14 : 20
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.maxX, y: r.maxY))
        path.curve(to: NSPoint(x: r.minX, y: r.maxY - flare),
                   controlPoint1: NSPoint(x: r.maxX, y: r.maxY - flare * 0.55),
                   controlPoint2: NSPoint(x: r.minX, y: r.maxY - flare * 0.45))
        path.line(to: NSPoint(x: r.minX, y: r.minY + flare))
        path.curve(to: NSPoint(x: r.maxX, y: r.minY),
                   controlPoint1: NSPoint(x: r.minX, y: r.minY + flare * 0.45),
                   controlPoint2: NSPoint(x: r.maxX, y: r.minY + flare * 0.55))
        path.close()
        if side == .left {
            var t = AffineTransform(translationByX: r.width, byY: 0)
            t.scale(x: -1, y: 1)
            path.transform(using: t)
        }
        return path
    }

    private func drawLights() {
        let d = Self.dotSize, gap = Self.dotGap
        let x = bounds.midX - d / 2
        if compact {
            // One light: green over yellow over red; dim when sessions are open but idle.
            let color = state.working ? Self.green : (state.waiting ? Self.yellow : Self.red)
            let on = state.working || state.waiting || state.idle
            drawDot(NSRect(x: x, y: bounds.midY - d / 2, width: d, height: d), color, on: on)
            return
        }
        let lights: [(Bool, NSColor)] = [(state.working, Self.green), (state.waiting, Self.yellow), (state.idle, Self.red)]
        var y = bounds.midY + (3 * d + 2 * gap) / 2 - d
        for (on, color) in lights {
            drawDot(NSRect(x: x, y: y, width: d, height: d), color, on: on)
            y -= d + gap
        }
    }

    private func drawDot(_ rect: NSRect, _ color: NSColor, on: Bool) {
        guard on else {
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = 4
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A click brings omux forward; a drag moves the panel up or down along its edge.
    override func mouseDown(with event: NSEvent) {
        guard let w = window, let c = controller else { return }
        let grabOffsetY = NSEvent.mouseLocation.y - w.frame.origin.y
        let startY = w.frame.origin.y
        var didDrag = false
        // Track events here until the mouse is released.
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let targetY = NSEvent.mouseLocation.y - grabOffsetY
            if !didDrag && abs(targetY - startY) > 3 { didDrag = true }
            if didDrag { c.place(y: targetY) }
        }
        if didDrag { c.saveY() } else { c.bringOmuxForward() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Snap to either edge, compact, hide. nil once the controller is gone.
    private func contextMenu() -> NSMenu? {
        guard let c = controller else { return nil }
        let menu = NSMenu()
        let left = menu.addItem(withTitle: "Snap to Left Edge", action: #selector(EdgeLight.snapLeft), keyEquivalent: "")
        let right = menu.addItem(withTitle: "Snap to Right Edge", action: #selector(EdgeLight.snapRight), keyEquivalent: "")
        left.state = side == .left ? .on : .off
        right.state = side == .right ? .on : .off
        menu.addItem(.separator())
        let small = menu.addItem(withTitle: "Compact", action: #selector(EdgeLight.toggleCompact), keyEquivalent: "")
        small.state = compact ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide", action: #selector(EdgeLight.hideFromMenu), keyEquivalent: "")
        for item in menu.items { item.target = c }
        return menu
    }
}
