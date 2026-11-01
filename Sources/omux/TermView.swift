import AppKit
import SwiftTerm
import SwiftUI

enum TermEvent {
    case bell
    case title(String)
    case directory(String?)
    case exited
    /// OSC 7501: the root record's state, kind and message, plus every other record.
    case status(TabRuntime.StatusState?, kind: String?, message: String?, children: [TabRuntime.StatusChild])
    /// ⌘-click on a file path in the output.
    case openPath(String)
    /// A desktop notification the program asked for (OSC 9 or OSC 777).
    case notification(title: String?, body: String)
}

/// Receives process callbacks on behalf of a TermView. Kept separate because
/// LocalProcessTerminalView already declares methods with these signatures.
private final class ProcessEvents: LocalProcessTerminalViewDelegate {
    weak var owner: TermView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.emit(.title(title))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 sends a file:// URL
        let path = directory.flatMap { URL(string: $0)?.path ?? $0 }
        owner?.emit(.directory(path))
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.emit(.exited)
        owner?.releaseAfterExit()
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        owner?.emit(.exited)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        let children = records.filter { !$0.id.isEmpty }.map {
            TabRuntime.StatusChild(id: $0.id, state: TabRuntime.StatusState(rawValue: $0.state.rawValue),
                                   kind: $0.kind?.rawValue, message: $0.message, title: $0.title)
        }
        guard let root = records.first(where: { $0.id.isEmpty }) ?? records.last else {
            owner?.emit(.status(nil, kind: nil, message: nil, children: []))
            return
        }
        let state = TabRuntime.StatusState(rawValue: root.state.rawValue)
        owner?.emit(.status(state, kind: root.kind?.rawValue, message: root.message, children: children))
    }
}

final class TermView: LocalProcessTerminalView {
    let tabID: UUID
    var onEvent: ((TermEvent) -> Void)?
    private let events = ProcessEvents()
    private var oscObservation: TerminalOscObservation?

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                   font: Fonts.terminal(),
                   options: TerminalOptions(scrollback: 5000))
        events.owner = self
        processDelegate = events
        // Option composes the layout's character (⌥Q is "@" on a Turkish layout) and
        // stays Meta only on keys with no character: arrows, ⌥⏎, ⌥⌫, Escape, Tab.
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        apply(Theme.current)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        // Observed, not handled, so SwiftTerm keeps drawing OSC 9;4 progress itself.
        oscObservation = observeOscEvents { [weak self] event in
            guard let note = Self.notification(code: event.code, payload: event.payload) else { return }
            Task { @MainActor in self?.emit(.notification(title: note.title, body: note.body)) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The last `count` lines on screen (and just above it), without trailing blank lines.
    /// For the `omux screen` command.
    func lastLines(_ count: Int) -> [String] {
        guard let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: count)) else { return [] }
        var lines = snapshot.rows.map { row in
            String(row.text.reversed().drop { $0 == " " }.reversed())
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    func apply(_ theme: Theme) {
        font = Fonts.terminal()
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.foreground
        installColors(theme.palette)
    }

    /// Closed sessions whose shell is still exiting. Released at once, the view stops reading
    /// the PTY but keeps it open until the shell is reaped, and a shell that prints on its way
    /// out (an agent's goodbye, a TUI restoring the screen) then waits forever for that output
    /// to drain: a stuck shell, PTY and thread per close.
    private static var exiting: Set<TermView> = []

    /// Keeps the view reading until its shell exits, or for 30 s at most.
    func keepUntilExit() {
        Self.exiting.insert(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.releaseAfterExit() }
    }

    fileprivate func releaseAfterExit() {
        if Thread.isMainThread { Self.exiting.remove(self) } else { DispatchQueue.main.async { Self.exiting.remove(self) } }
    }

    fileprivate func emit(_ event: TermEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    /// ⌘-click: file paths go to the preview panel, folders (app bundles too) are shown in
    /// Finder rather than opened, everything else (URLs) goes to the system.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let path = Self.filePath(from: link) {
            emit(.openPath(path))
        } else if let folder = Self.filePath(from: link, folders: true) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }

    nonisolated static func filePath(from link: String, folders: Bool = false) -> String? {
        var raw = link.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("file://"), let url = URL(string: raw) { raw = url.path }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return nil }
        // Drop trailing punctuation Claude's prose leaves on paths.
        while let last = raw.last, ".,:;)]}'\"".contains(last) { raw.removeLast() }
        var path = (raw as NSString).expandingTildeInPath
        // "Foo.swift:12" and "Foo.swift:12:4", as compilers and agents print locations.
        if !FileManager.default.fileExists(atPath: path),
           let location = path.range(of: #":[0-9]+(:[0-9]+)?\z"#, options: .regularExpression) {
            path = String(path[..<location.lowerBound])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue == folders else { return nil }
        return path
    }

    // MARK: Images and files

    /// ⌘V with files or an image on the clipboard pastes their paths, which Claude Code and
    /// Codex read as attachments. Text pastes as before; an image only wins when there is no text.
    override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        do {
            if let text = try Self.attachmentText(from: board) {
                paste(text)
            } else {
                super.paste(sender)
            }
        } catch {
            NSSound.beep()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        let readable = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || board.canReadObject(forClasses: [NSImage.self, NSFilePromiseReceiver.self], options: nil)
        return readable && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        do {
            // Photos and browsers hand over a promise of the file, not the file itself.
            if !board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
                window?.makeFirstResponder(self)
                try receive(promises)
                return true
            }
            guard let text = try Self.attachmentText(from: board, preferText: false) else { return false }
            window?.makeFirstResponder(self)
            paste(text)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Pastes each promised file's path as it arrives, in a folder of its own so names can't collide.
    private func receive(_ promises: [NSFilePromiseReceiver]) throws {
        let dir = Self.attachmentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                if error == nil {
                    self?.paste(Self.shellEscaped([url]) + " ")
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// Preserve ordinary text pastes; file URLs and image-only clipboard contents become paths.
    static func attachmentText(from board: NSPasteboard, preferText: Bool = true,
                               directory: URL? = nil) throws -> String? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return shellEscaped(urls) + " "
        }
        if preferText, board.string(forType: .string) != nil { return nil }
        guard let image = NSImage(pasteboard: board) else { return nil }
        return shellEscaped([try save(image, directory: directory)]) + " "
    }

    /// Paths the way a shell, Claude Code and Codex read them: spaces and specials escaped.
    /// Control characters become $'\xNN', so a newline in a name can't end the command.
    nonisolated static func shellEscaped(_ urls: [URL]) -> String {
        urls.map { url in
            url.path.unicodeScalars.map { ch in
                if ch.value < 0x20 || ch.value == 0x7f { return String(format: "$'\\x%02x'", ch.value) }
                return " '\"()[]{}&;|<>$`\\*?#~!".unicodeScalars.contains(ch) ? "\\\(ch)" : String(ch)
            }.joined()
        }.joined(separator: " ")
    }

    private static var attachmentDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omux-paste", isDirectory: true)
    }

    /// Saves a pasted image as PNG under the temporary folder, like the browser's picks.
    private static func save(_ image: NSImage, directory: URL?) throws -> URL {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = directory ?? attachmentDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        return url
    }

    /// Types text into the session as a paste, so newlines don't submit it early.
    func paste(_ text: String) {
        if terminalInputStateSnapshot()?.bracketedPasteMode == true {
            send(txt: Self.bracketedPaste(text))
        } else {
            send(txt: text)
        }
    }

    /// Without ESC, text from a file name or a log can't end the paste with its own
    /// ESC[201~ and have the lines after it typed and submitted.
    nonisolated static func bracketedPaste(_ text: String) -> String {
        "\u{1b}[200~" + text.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~"
    }

    /// The main buffer's text, scrollback included. Read it here on the main actor;
    /// the parsers below are safe to run on the copy from any thread.
    func scrollbackText() -> String {
        String(data: getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
    }

    /// A desktop notification in an OSC payload: `OSC 9 ; body` (iTerm2) or
    /// `OSC 777 ; notify ; title ; body` (Ghostty, rxvt). Claude Code sends these when its
    /// notification channel is `iterm2` or `ghostty`, for itself and for its plugins.
    nonisolated static func notification(code: Int, payload: [UInt8]) -> (title: String?, body: String)? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        switch code {
        case 9:
            // A number first is a ConEmu command, like 9;4 progress, not a message.
            guard !text.isEmpty, text.range(of: #"^\d+(;|$)"#, options: .regularExpression) == nil else { return nil }
            return (nil, text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "notify", !parts[2].isEmpty else { return nil }
            return (parts[1].isEmpty ? nil : String(parts[1]), String(parts[2]))
        default:
            return nil
        }
    }

    /// Local server URLs (localhost, 127.0.0.1, …) in `text`, oldest first.
    nonisolated static func mentionedLocalURLs(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s'"<>)\]]*)?"#)
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            var url = String(text[range])
            while let last = url.last, ".,:;".contains(last) { url.removeLast() }
            result.removeAll { $0 == url }
            result.append(url)
        }
        return result
    }

    /// File paths that appear in `text` and still exist, oldest first.
    nonisolated static func mentionedPaths(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?<![\w])(?:~|/)[\w.+@%~/-]+"#)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let path = Self.filePath(from: String(text[range])) else { continue }
            if seen.insert(path).inserted { result.append(path) } else if let i = result.firstIndex(of: path) {
                result.remove(at: i); result.append(path)
            }
        }
        return result
    }

    override nonisolated func bell(source: Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async {
            NSSound.beep()
            self.onEvent?(.bell)
        }
    }
}

/// Hosts the long-lived TermView for the selected tab. Terminal views are owned by
/// the Store so switching tabs reparents a view instead of recreating the session.
struct TerminalHost: NSViewRepresentable {
    let termView: TermView
    let theme: Theme
    /// Called on a click anywhere in the terminal, before the terminal handles it.
    var onClick: (() -> Void)? = nil
    /// A session dragged over the terminal: the edge it would land on, or nil when it leaves.
    var onDragEdge: ((Edge?) -> Void)? = nil
    /// A session dropped on the terminal, with the edge it landed on.
    var onDropSession: ((UUID, Edge) -> Void)? = nil

    final class Coordinator { var currentID: UUID? }

    /// Notices clicks on the way to the terminal without taking them, and takes sessions
    /// dragged from the sidebar or another pane (AppKit drags, which SwiftUI's own drop
    /// targets don't receive from a List).
    final class Container: NSView {
        var onClick: (() -> Void)?
        var onDragEdge: ((Edge?) -> Void)?
        var onDropSession: ((UUID, Edge) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
        }

        required init?(coder: NSCoder) { fatalError("not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let view = super.hitTest(point)
            if view != nil, let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
               let onClick {
                DispatchQueue.main.async(execute: onClick)
            }
            return view
        }

        private func session(in info: NSDraggingInfo) -> UUID? {
            info.draggingPasteboard.string(forType: .string).flatMap(UUID.init(uuidString:))
        }

        /// The edge nearest to the point, as a share of each side; flipped so top is top.
        private func edge(for info: NSDraggingInfo) -> Edge {
            let p = convert(info.draggingLocation, from: nil)
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return .trailing }
            let y = isFlipped ? p.y : size.height - p.y
            let shares: [(Edge, CGFloat)] = [(.leading, p.x / size.width), (.trailing, 1 - p.x / size.width),
                                             (.top, y / size.height), (.bottom, 1 - y / size.height)]
            return shares.min(by: { $0.1 < $1.1 })?.0 ?? .trailing
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard session(in: sender) != nil else { return [] }
            onDragEdge?(edge(for: sender))
            return .move
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard session(in: sender) != nil else { return [] }
            onDragEdge?(edge(for: sender))
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { onDragEdge?(nil) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let landing = edge(for: sender)
            onDragEdge?(nil)
            guard let id = session(in: sender) else { return false }
            onDropSession?(id, landing)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        container.onClick = onClick
        container.onDragEdge = onDragEdge
        container.onDropSession = onDropSession
        container.layer?.backgroundColor = theme.background.cgColor
        guard context.coordinator.currentID != termView.tabID || termView.superview !== container else { return }
        context.coordinator.currentID = termView.tabID
        container.subviews.forEach { $0.removeFromSuperview() }
        termView.frame = container.bounds
        termView.autoresizingMask = [.width, .height]
        container.addSubview(termView)
        DispatchQueue.main.async {
            termView.window?.makeFirstResponder(termView)
        }
    }
}
