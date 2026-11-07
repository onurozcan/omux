import AppKit
import Combine
import ObjectiveC
import SwiftUI

/// View › Screen Off: the screens go dark while agents keep working. Only while Keep Awake holds,
/// so its heat, battery and time limits apply; when it stops, the displays may sleep again. The omux ring draws itself,
/// takes one breath and goes out to a point, then the screens stay black and the built-in display's
/// brightness and the keyboard lights go all the way down; a key or click plays it back. The displays
/// aren't put to sleep, since that would lock the Mac. With Reduce Motion it's a plain fade. Closing
/// the lid while Keep Awake holds plays a quick version on the built-in screen (see LidWatcher),
/// which never takes focus or keys, so clamshell use with an external display isn't disturbed.
@MainActor
final class ScreenOff {
    static let shared = ScreenOff()

    /// What the ring is doing, animated by BreatheOutView.
    final class Model: ObservableObject {
        @Published var backdrop: Double = 0
        @Published var progress: CGFloat = 0
        @Published var glow: CGFloat = 0
        @Published var scale: CGFloat = 1
        @Published var ring: Double = 1
        @Published var caption: Double = 0
    }

    private var windows: [NSWindow] = []
    private var model = Model()
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var sequence: Task<Void, Never>?
    private var lid = false
    /// Keeps the displays from sleeping while dark: display sleep would lock the Mac. Only while
    /// Keep Awake holds.
    private var displayActivity: NSObjectProtocol?
    private var holding: AnyCancellable?
    private var screensChanged: NSObjectProtocol?
    /// The built-in display's brightness before the lid dimmed it, to put back.
    private var savedBrightness: (display: CGDirectDisplayID, level: Float)?

    var isShowing: Bool { !windows.isEmpty }

    /// Screen Off is offered only while Keep Awake holds.
    static var isAvailable: Bool { KeepAwake.shared.isHolding }

    /// `lid`: started by closing the lid, so only the built-in screen, quickly, and without
    /// taking focus.
    func start(lid: Bool = false) {
        guard !isShowing, Self.isAvailable else { return }
        let screens = lid ? NSScreen.screens.filter(\.isBuiltIn) : NSScreen.screens
        guard !screens.isEmpty else { return }
        self.lid = lid
        model = Model()
        beginDisplayActivity()
        // Keep Awake stopped (heat, battery, time limit, turned off): let the displays sleep as
        // usual, until it holds again. The screen stays dark until someone comes back.
        holding = KeepAwake.shared.$decision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] decision in
                MainActor.assumeIsolated {
                    if case .hold = decision { self?.beginDisplayActivity() } else { self?.endDisplayActivity() }
                }
            }
        let agents = KeepAwake.shared.activeAgents
        let caption = agents == 0 ? "Screen off" : "\(agents) agent\(agents == 1 ? "" : "s") working · screen off"
        let main = lid ? screens.first : NSScreen.main
        for screen in screens {
            let window = CurtainWindow(takesKeys: !lid, contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            // The lid's curtain only covers; opening the lid takes it away.
            window.ignoresMouseEvents = lid
            window.contentView = NSHostingView(rootView: BreatheOutView(model: model, caption: caption,
                                                                        showsRing: screen == main,
                                                                        cancel: { [weak self] in self?.wake() }))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        if !lid {
            // From the menu: a key brings the screen back, so omux takes keys for the moment.
            windows.first?.makeKey()
            NSApp.activate()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] _ in
                self?.wake()
                return nil
            }
        } else {
            // A lid closed all the way with an external display removes the built-in screen,
            // and AppKit would move the curtain onto the external one.
            screensChanged = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideOffBuiltInScreen() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
        sequence = Task { await goDark() }
    }

    /// In lid mode, takes the curtain off any screen that isn't the built-in one. With the
    /// built-in screen gone and another one left, someone is working on that one, so the time
    /// limit stops counting; opening the lid ends the curtain.
    private func hideOffBuiltInScreen() {
        for window in windows where window.screen.map({ !$0.isBuiltIn }) ?? true {
            window.orderOut(nil)
        }
        let screens = NSScreen.screens
        if !screens.isEmpty, !screens.contains(where: \.isBuiltIn) {
            KeepAwake.shared.setCurtainDark(false)
        }
    }

    private func beginDisplayActivity() {
        guard displayActivity == nil else { return }
        displayActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "omux: Screen Off")
    }

    private func endDisplayActivity() {
        if let displayActivity { ProcessInfo.processInfo.endActivity(displayActivity) }
        displayActivity = nil
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func goDark() async {
        let model = model
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) { model.backdrop = 1 }
            guard await pause(0.35) else { return }
        } else if lid {
            // The lid closes in about a second: draw (0.25 s), out to a point (0.3 s), black.
            withAnimation(.easeOut(duration: 0.2)) { model.backdrop = 0.9 }
            withAnimation(.easeOut(duration: 0.25)) { model.progress = 1; model.glow = 0.8 }
            guard await pause(0.25) else { return }
            withAnimation(.timingCurve(0.6, 0, 0.4, 1, duration: 0.3)) { model.scale = 0.06 }
            guard await pause(0.28) else { return }
            withAnimation(.easeOut(duration: 0.1)) { model.ring = 0; model.backdrop = 1 }
            guard await pause(0.1) else { return }
        } else {
            // Draw (0.6 s), one breath (1 s), out to a point (0.5 s), then black.
            withAnimation(.easeOut(duration: 0.3)) { model.backdrop = 0.88 }
            withAnimation(.easeOut(duration: 0.6)) { model.progress = 1 }
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) { model.caption = 1 }
            guard await pause(0.6) else { return }
            withAnimation(.easeInOut(duration: 0.5)) { model.glow = 1 }
            guard await pause(0.5) else { return }
            withAnimation(.easeInOut(duration: 0.5)) { model.glow = 0.35 }
            guard await pause(0.5) else { return }
            withAnimation(.easeIn(duration: 0.3)) { model.caption = 0 }
            withAnimation(.timingCurve(0.6, 0, 0.4, 1, duration: 0.5)) { model.scale = 0.06 }
            guard await pause(0.45) else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.ring = 0; model.backdrop = 1 }
            guard await pause(0.2) else { return }
        }
        // Already on an external display alone (the lid shut all the way during the animation):
        // nobody is in the dark.
        if !lid || NSScreen.screens.contains(where: \.isBuiltIn) || NSScreen.screens.isEmpty {
            KeepAwake.shared.setCurtainDark(true)
        }
        await dim()
    }

    /// Plays the ring back and removes the curtain.
    func wake() {
        guard isShowing, sequence != nil else { return }
        sequence?.cancel()
        sequence = nil
        restoreBrightness()
        KeepAwake.shared.setCurtainDark(false)
        let model = model
        Task {
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.3)) { model.backdrop = 0 }
            } else {
                model.ring = 1
                withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.4)) { model.scale = 1; model.glow = 0.6 }
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.3)) { model.backdrop = 0; model.ring = 0; model.caption = 0 }
            }
            try? await Task.sleep(for: .milliseconds(320))
            finish()
        }
    }

    private func finish() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        if let screensChanged { NotificationCenter.default.removeObserver(screensChanged) }
        screensChanged = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        lid = false
        holding = nil
        endDisplayActivity()
    }

    /// False if the sequence was cancelled meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return !Task.isCancelled
    }


    /// Brings the built-in display's brightness to zero over a moment, remembering where it was.
    private func dim() async {
        guard let display = NSScreen.screens.first(where: \.isBuiltIn)?.displayID,
              let level = Brightness.get(display), level > 0 else { return }
        savedBrightness = (display, level)
        KeyboardBacklight.shared.turnOff()
        for step in stride(from: 1, through: 6, by: 1) {
            Brightness.set(display, level * Float(6 - step) / 6)
            guard await pause(0.04) else { return }
        }
    }

    /// Puts the brightness back if the lid dimmed it. Also called when omux quits.
    func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        savedBrightness = nil
        Brightness.set(saved.display, saved.level)
        KeyboardBacklight.shared.restore()
    }

    /// Borderless, but takes keys, so a key press during the animation brings the screen back
    /// (not in lid mode, which never makes it key).
    private final class CurtainWindow: NSWindow {
        private var takesKeys = true

        convenience init(takesKeys: Bool, contentRect: NSRect, styleMask: NSWindow.StyleMask,
                         backing: NSWindow.BackingStoreType, defer flag: Bool) {
            self.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
            self.takesKeys = takesKeys
        }

        override var canBecomeKey: Bool { takesKeys }
    }
}

struct BreatheOutView: View {
    @ObservedObject var model: ScreenOff.Model
    let caption: String
    let showsRing: Bool
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(model.backdrop)
            if showsRing {
                VStack(spacing: 22) {
                    AwakeRing(size: 120, progress: model.progress, glow: model.glow)
                        .scaleEffect(model.scale)
                        .opacity(model.ring)
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(Color(white: 0.55))
                        .opacity(model.caption)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: cancel)
    }
}

extension NSScreen {
    /// The MacBook's own display, the one the lid covers.
    var isBuiltIn: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}

/// The built-in display's backlight, through DisplayServices: the private framework the brightness
/// keys and Control Center use, since there's no public API for it. Loaded at run time, so if it's
/// missing or changes, dimming is skipped and the screen just stays black.
enum Brightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = framework.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = framework.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    static func get(_ display: CGDirectDisplayID) -> Float? {
        var level: Float = 0
        guard let getter, getter(display, &level) == 0 else { return nil }
        return level
    }

    static func set(_ display: CGDirectDisplayID, _ level: Float) {
        _ = setter?(display, min(max(level, 0), 1))
    }
}

/// The keyboard's backlight, through CoreBrightness's KeyboardBrightnessClient: private, like
/// DisplayServices, and loaded at run time, so on a Mac without it nothing happens. Changes aren't
/// committed, so the user's keyboard brightness setting is never overwritten.
@MainActor
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    private typealias GetLevel = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetLevel = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
    private typealias GetFlag = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetFlag = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private let client: NSObject?
    private var saved: (keyboard: UInt64, level: Float, auto: Bool)?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }

    private func method<T>(_ name: String, as type: T.Type) -> (T, Selector)? {
        let selector = NSSelectorFromString(name)
        guard let client, client.responds(to: selector),
              let imp = class_getMethodImplementation(Swift.type(of: client), selector) else { return nil }
        return (unsafeBitCast(imp, to: type), selector)
    }

    private var keyboard: UInt64? {
        guard let client, client.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")),
              let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return ids.first?.uint64Value
    }

    func turnOff() {
        guard saved == nil, let client, let keyboard,
              let (get, getSel) = method("brightnessForKeyboard:", as: GetLevel.self),
              let (set, setSel) = method("setBrightness:fadeSpeed:commit:forKeyboard:", as: SetLevel.self) else { return }
        let auto = method("isAutoBrightnessEnabledForKeyboard:", as: GetFlag.self).map { $0.0(client, $0.1, keyboard) } ?? false
        saved = (keyboard, get(client, getSel, keyboard), auto)
        _ = set(client, setSel, 0, 250, false, keyboard)
    }

    func restore() {
        guard let saved, let client else { return }
        self.saved = nil
        if saved.level > 0, let (set, setSel) = method("setBrightness:fadeSpeed:commit:forKeyboard:", as: SetLevel.self) {
            _ = set(client, setSel, saved.level, 250, false, saved.keyboard)
        }
        // With automatic keyboard brightness, hand control back to it.
        if saved.auto, let (enable, enableSel) = method("enableAutoBrightness:forKeyboard:", as: SetFlag.self) {
            _ = enable(client, enableSel, true, saved.keyboard)
        }
    }
}
