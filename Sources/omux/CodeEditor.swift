import AppKit
import SwiftUI
import WebKit

// A small editor for the Files panel: edit a text file in place and save it. The page is the
// textarea-over-highlight trick (Resources/transcript/editor.*), so editing is native and the
// colors are highlight.js's. Nothing here tries to be an IDE.

/// A text file open for editing: its contents, whether they differ from disk, and what to do
/// when the file changes under us.
@MainActor
final class FileDocument: ObservableObject {
    let url: URL
    @Published private(set) var text = ""
    @Published private(set) var dirty = false
    /// The file changed on disk while there were unsaved edits.
    @Published private(set) var changedOnDisk = false
    @Published private(set) var error: String?
    /// Bumped when `text` should replace what the editor shows: a load, a reload, a revert.
    @Published private(set) var generation = 0
    private var modified: Date?
    private var watcher: DispatchSourceFileSystemObject?

    /// Beyond this the panel shows the file read-only, as before.
    static let maxBytes = 1_000_000

    init(url: URL) {
        self.url = url
        load()
        watch()
    }

    deinit { watcher?.cancel() }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8) else { error = "Not a UTF-8 text file"; return }
            text = string
            modified = Self.modified(url)
            dirty = false
            changedOnDisk = false
            error = nil
            generation += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Follows writes and replacements (editors and agents often write a new file over the old).
    private func watch() {
        watcher?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.fileChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func fileChanged() {
        // A replaced file needs a new descriptor to keep following it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { error = "The file was deleted"; return }
            let now = Self.modified(url)
            guard now != modified else { return }
            if dirty { changedOnDisk = true } else { load() }
            watch()
        }
    }

    /// What the editor holds now; `dirty` follows from it.
    func edited(_ isDirty: Bool) {
        dirty = isDirty
        if !isDirty { changedOnDisk = false }
    }

    /// Writes in place, so permissions and the inode stay; refuses to overwrite a file that
    /// changed on disk unless told to.
    func save(_ contents: String, overwrite: Bool = false) {
        if changedOnDisk, !overwrite { return }
        do {
            try Data(contents.utf8).write(to: url)
            text = contents
            modified = Self.modified(url)
            dirty = false
            changedOnDisk = false
            error = nil
            // A copy of a file on another machine goes back to where it came from.
            RemoteFiles.saved(url)
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Drops the edits and shows what's on disk.
    func revert() { load(); watch() }
}

/// The editor page in a web view, fed a document and reporting edits and saves.
struct CodeEditorView: NSViewRepresentable {
    @ObservedObject var document: FileDocument
    let language: String?
    let wrap: Bool
    let theme: Theme
    let onSave: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(document: document, onSave: onSave) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = OmuxWebKit.pool
        config.userContentController.add(context.coordinator, name: "omux")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = view
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("transcript", isDirectory: true) {
            view.loadFileURL(dir.appendingPathComponent("editor.html"), allowingReadAccessTo: dir)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onSave = onSave
        context.coordinator.update(text: document.text, generation: document.generation, language: language, wrap: wrap, theme: theme)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "omux")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        let document: FileDocument
        var onSave: (String) -> Void
        private var ready = false
        private var shownGeneration = -1
        private var shownWrap: Bool?
        private var themeJSON: String?
        private var pending: (text: String, generation: Int, language: String?, wrap: Bool)?

        init(document: FileDocument, onSave: @escaping (String) -> Void) {
            self.document = document
            self.onSave = onSave
        }

        func update(text: String, generation: Int, language: String?, wrap: Bool, theme: Theme) {
            let themeJSON = Self.themeJSON(theme)
            if themeJSON != self.themeJSON {
                self.themeJSON = themeJSON
                if ready { webView?.evaluateJavaScript("editor.setTheme(\(themeJSON))") }
            }
            guard ready else { pending = (text, generation, language, wrap); return }
            if generation != shownGeneration {
                let first = shownGeneration < 0
                shownGeneration = generation
                shownWrap = wrap
                let doc = Self.json(["text": text, "language": language ?? "", "wrap": wrap])
                webView?.evaluateJavaScript(first ? "editor.load(\(doc)); editor.focus()" : "editor.replace(\(doc))")
            } else if wrap != shownWrap {
                shownWrap = wrap
                webView?.evaluateJavaScript("editor.setWrap(\(wrap))")
            }
        }

        /// Tells the page its text is what's on disk now.
        func markSaved() { webView?.evaluateJavaScript("editor.markSaved()") }

        private static func json(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        private static func themeJSON(_ theme: Theme) -> String {
            func hex(_ color: NSColor) -> String {
                let c = color.usingColorSpace(.sRGB) ?? color
                return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            }
            func luminance(_ color: NSColor) -> CGFloat {
                let c = color.usingColorSpace(.sRGB) ?? color
                return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            }
            let font = Fonts.terminal()
            return json(["bg": hex(theme.background), "fg": hex(theme.foreground), "accent": hex(Appearance.accent),
                         "dark": luminance(theme.background) < 0.5, "size": 12,
                         "mono": "'\(font.familyName ?? "Menlo")', ui-monospace, Menlo, monospace"])
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            Task { @MainActor in decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
                switch type {
                case "ready":
                    ready = true
                    if let themeJSON { webView?.evaluateJavaScript("editor.setTheme(\(themeJSON))") }
                    if let pending {
                        self.pending = nil
                        update(text: pending.text, generation: pending.generation, language: pending.language, wrap: pending.wrap, theme: .dark)
                        if let themeJSON { webView?.evaluateJavaScript("editor.setTheme(\(themeJSON))") }
                    }
                case "dirty":
                    document.edited(body["dirty"] as? Bool ?? false)
                case "save":
                    if let text = body["text"] as? String { onSave(text) }
                default:
                    break
                }
            }
        }
    }
}

/// A text file in the Files panel: the editor, a line underneath with the file's state and the
/// Save and Revert buttons, and a notice when the file changed on disk during edits.
struct FileEditorPane: View {
    let url: URL
    let wrap: Bool
    let theme: Theme
    @StateObject private var document: FileDocument
    @State private var coordinatorSave: ((String) -> Void)?
    @State private var latest = ""

    init(url: URL, wrap: Bool, theme: Theme) {
        self.url = url
        self.wrap = wrap
        self.theme = theme
        _document = StateObject(wrappedValue: FileDocument(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = document.error {
                Text(error).font(.caption).foregroundStyle(Palette.error).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            CodeEditorView(document: document, language: Self.language(for: url), wrap: wrap, theme: theme) { text in
                latest = text
                save(text)
            }
            if document.changedOnDisk {
                HStack(spacing: 8) {
                    Circle().fill(Palette.needs).frame(width: 7, height: 7)
                    Text("Changed on disk while you were editing.").font(.system(size: 11))
                    Button("Reload") { document.revert() }.buttonStyle(.bordered)
                    Button("Save mine") { document.save(latest, overwrite: true) }.buttonStyle(.borderedProminent)
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Palette.needs.opacity(0.1))
            }
            HStack(spacing: 10) {
                if document.dirty {
                    Circle().fill(Palette.needs).frame(width: 6, height: 6)
                    Text("Modified").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Button("Revert") { document.revert() }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Text(Self.language(for: url).map { "\($0) · " } ?? "").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        + Text("⌘S saves").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Save") { save(latest) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(!document.dirty || document.changedOnDisk)
                    .help("Save (⌘S)")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        }
    }

    private func save(_ text: String) {
        guard !text.isEmpty || document.text.isEmpty else { return }
        document.save(text)
    }

    /// highlight.js language names by extension, from the common bundle the app ships.
    static func language(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        switch name {
        case "dockerfile", "makefile", ".zshrc", ".bashrc", ".zprofile", ".bash_profile", ".profile": return name == "makefile" ? "makefile" : "bash"
        case ".gitignore", ".env", ".env.local", ".env.example", ".editorconfig": return name == ".env" || name.hasPrefix(".env.") ? "bash" : "ini"
        default: break
        }
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "php": return "php"
        case "sh", "zsh", "bash", "command": return "bash"
        case "json", "jsonc", "lock": return "json"
        case "yaml", "yml": return "yaml"
        case "toml", "ini", "cfg", "conf", "plist": return ext == "plist" ? "xml" : "ini"
        case "xml", "html", "htm", "svg", "xib", "storyboard", "entitlements": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "md", "markdown", "mdx": return "markdown"
        case "sql": return "sql"
        case "lua": return "lua"
        case "r": return "r"
        case "pl": return "perl"
        case "diff", "patch": return "diff"
        case "graphql", "gql": return "graphql"
        case "txt", "log", "csv": return nil
        default: return nil
        }
    }
}
