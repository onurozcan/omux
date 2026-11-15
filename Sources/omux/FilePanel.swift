import AppKit
import AVKit
import PDFKit
import Quartz
import SwiftUI

// MARK: - Model

/// A lazily expanded folder tree node. Identity is the path so expansion survives refreshes.
final class FileNode: Identifiable {
    static let skipped: Set<String> = ["node_modules", ".git", ".build", "DerivedData", "__pycache__", ".venv", "venv"]

    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    private var cached: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if cached == nil { cached = load() }
        return cached
    }

    func invalidate() {
        cached?.forEach { $0.invalidate() }
        cached = nil
    }

    private func load() -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let byDate = UserDefaults.standard.bool(forKey: Prefs.filesByDate)
        let nodes = items.compactMap { item -> (FileNode, Date)? in
            guard !Self.skipped.contains(item.lastPathComponent),
                  let values = try? item.resourceValues(forKeys: Set(keys)) else { return nil }
            return (FileNode(url: item, isDirectory: values.isDirectory ?? false), values.contentModificationDate ?? .distantPast)
        }
        let sorted = nodes.sorted { a, b in
            if a.0.isDirectory != b.0.isDirectory { return a.0.isDirectory }
            return byDate ? a.1 > b.1 : a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }
        return sorted.prefix(500).map(\.0)
    }
}

/// FSEvents on a folder tree, coalesced to one callback per second.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

// MARK: - Panel

struct FilePanel: View {
    @EnvironmentObject var store: Store
    let root: URL
    let theme: Theme
    /// Files is the panel's tab in view. Behind another tab it stays alive but stops scanning.
    var visible = true
    @AppStorage(Prefs.filesByDate) private var byDate = false
    @AppStorage(Prefs.filesBrowserCollapsed) private var browserCollapsed = false

    /// Whether the list of mentioned files can be seen at all; reading the scrollback for it is
    /// the dear part.
    private var listsMentions: Bool { visible && !browserCollapsed }
    @State private var rootNode: FileNode?
    @State private var watcher: FolderWatcher?
    @State private var version = 0
    @State private var selected: String?
    /// The row the highlight is on: "m:" and a path for a mentioned file, "t:" and one for the tree.
    @State private var cursor: String?
    /// The folders shown open.
    @State private var expanded: Set<String> = []
    @FocusState private var listFocused: Bool
    @State private var previewURL: URL?

    var body: some View {
        Group {
            if previewURL == nil, !browserCollapsed {
                // Nothing open: the folder gets the whole panel.
                browser
            } else {
                VSplitView {
                    Group {
                        if let url = previewURL {
                            FilePreview(url: url) { previewURL = nil; selected = nil; cursor = nil }
                        } else {
                            EmptyState(icon: "doc.text.magnifyingglass", title: "No file open", detail: "Show the folder below and pick a file.")
                        }
                    }
                    .frame(minHeight: 200)
                    .background(Color(nsColor: theme.background))
                    .layoutPriority(1)

                    browser
                        .frame(minHeight: browserCollapsed ? 30 : 80, idealHeight: browserCollapsed ? 30 : 180, maxHeight: browserCollapsed ? 30 : .infinity)
                }
            }
        }
        .background(Color(nsColor: theme.chrome))
        .onAppear { load(); showRequested(); store.scanMentionedPaths() }
        .onChange(of: root) { _, _ in load() }
        .onChange(of: store.previewRequest) { _, _ in showRequested() }
        .onChange(of: store.selectedTabID) { _, _ in if listsMentions { store.scanMentionedPaths() } }
        .onChange(of: listsMentions) { _, shown in if shown { store.scanMentionedPaths() } }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in if listsMentions { store.scanMentionedPaths() } }
        .onChange(of: byDate) { _, _ in refresh() }
        .onChange(of: selected) { _, path in
            guard let path else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                show(URL(fileURLWithPath: path))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { show(url) }
            }
            return true
        }
    }

    /// The folder: its header, the files the session mentioned, and the tree.
    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browserCollapsed.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(browserCollapsed ? 0 : 90))
                        .frame(width: 10, height: 10)
                }
                .help(browserCollapsed ? "Show files" : "Hide files")
                Text(root.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if !browserCollapsed {
                    Button { byDate.toggle() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.arrow.down").font(.system(size: 8.5, weight: .semibold))
                            Text(byDate ? "Date" : "Name").font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(byDate ? "Sorted by date changed. Click to sort by name." : "Sorted by name. Click to sort by date changed.")
                }
                Button { NSWorkspace.shared.open(root) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open folder in Finder")
            }
            .panelHeader()

            if !browserCollapsed {
                ScrollViewReader { proxy in
                    List {
                        if !store.mentionedPaths.isEmpty {
                            Section("Mentioned in session") {
                                ForEach(store.mentionedPaths.reversed(), id: \.self) { path in
                                    let url = URL(fileURLWithPath: path)
                                    SoftRow(selected: isCursor("m:" + path, path: path)) { pick("m:" + path, path: path, node: nil) } content: {
                                        HStack(spacing: 5) {
                                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 14, height: 14)
                                            Text(url.lastPathComponent).lineLimit(1)
                                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                        }
                                    }
                                    .id("m:" + path)
                                }
                            }
                        }
                        Section(root.lastPathComponent) {
                            ForEach(treeRows, id: \.node.id) { row in
                                let node = row.node
                                SoftRow(selected: isCursor("t:" + node.id, path: node.id)) { pick("t:" + node.id, path: node.id, node: node) } content: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 7.5, weight: .bold))
                                            .foregroundStyle(.tertiary)
                                            .rotationEffect(.degrees(expanded.contains(node.id) ? 90 : 0))
                                            .frame(width: 10)
                                            .opacity(node.isDirectory ? 1 : 0)
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path)).resizable().frame(width: 14, height: 14)
                                        Text(node.name).lineLimit(1)
                                    }
                                    .padding(.leading, CGFloat(row.depth) * 14)
                                }
                                .id("t:" + node.id)
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(node.url) }
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                                    Button("Copy Path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(node.url.path, forType: .string)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    // Up and down walk the rows, right and left open and close a folder.
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .onKeyPress(.upArrow) { step(-1, proxy) }
                    .onKeyPress(.downArrow) { step(1, proxy) }
                    .onKeyPress(.rightArrow) { fold(open: true) }
                    .onKeyPress(.leftArrow) { fold(open: false) }
                }
            }
        }
    }

    // MARK: The tree, kept flat

    private struct TreeRow {
        let node: FileNode
        let depth: Int
    }

    /// The rows on screen: the folder's entries, with those of every open folder under it.
    private var treeRows: [TreeRow] {
        var rows: [TreeRow] = []
        func walk(_ nodes: [FileNode], _ depth: Int) {
            for node in nodes {
                rows.append(TreeRow(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.id) { walk(node.children ?? [], depth + 1) }
            }
        }
        walk(rootNode?.children ?? [], 0)
        return rows
    }

    /// Whether a row is the one picked: by its own key, or by its path when the pick came from
    /// outside the list (a path clicked in the transcript).
    private func isCursor(_ key: String, path: String) -> Bool {
        cursor.map { $0 == key } ?? (selected == path)
    }

    /// A click or the arrow keys landing on a row: a file is shown, a clicked folder opens or closes.
    private func pick(_ key: String, path: String, node: FileNode?, byKey: Bool = false) {
        cursor = key
        listFocused = true
        if let node, node.isDirectory {
            if !byKey { if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) } }
        } else {
            selected = path
        }
    }

    private func step(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let all: [(key: String, path: String, node: FileNode?)] =
            store.mentionedPaths.reversed().map { ("m:" + $0, $0, nil) } + treeRows.map { ("t:" + $0.node.id, $0.node.id, $0.node) }
        guard !all.isEmpty else { return .ignored }
        let at = all.firstIndex { row in cursor.map { $0 == row.key } ?? (row.path == selected) } ?? (by > 0 ? -1 : all.count)
        let next = all[min(max(at + by, 0), all.count - 1)]
        pick(next.key, path: next.path, node: next.node, byKey: true)
        proxy.scrollTo(next.key)
        return .handled
    }

    private func fold(open: Bool) -> KeyPress.Result {
        guard let cursor, cursor.hasPrefix("t:") else { return .ignored }
        let id = String(cursor.dropFirst(2))
        guard treeRows.contains(where: { $0.node.id == id && $0.node.isDirectory }) else { return .ignored }
        if open { expanded.insert(id) } else { expanded.remove(id) }
        return .handled
    }

    /// A page goes to the Browser tab, rendered; everything else previews here.
    private func show(_ url: URL) {
        if Store.opensInBrowser(url) { store.showInBrowser(url) } else { previewURL = url }
    }

    private func showRequested() {
        guard let path = store.previewRequest else { return }
        previewURL = URL(fileURLWithPath: path)
        selected = path
        cursor = nil
        store.previewRequest = nil
    }

    private func load() {
        rootNode = FileNode(url: root, isDirectory: true)
        selected = nil
        cursor = nil
        expanded = []
        previewURL = nil
        version += 1
        watcher = FolderWatcher(path: root.path) { refresh() }
    }

    private func refresh() {
        rootNode?.invalidate()
        version += 1
    }
}

// MARK: - Preview

struct FilePreview: View {
    let url: URL
    /// Closes the preview, where the panel can show something else in its place.
    var onClose: (() -> Void)?
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true
    @AppStorage(Prefs.theme) private var themeName = Theme.black.rawValue
    /// Markdown shows rendered until the pencil switches it to the editor.
    @State private var editingMarkdown = false

    private var theme: Theme { Theme(rawValue: themeName) ?? .black }

    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "bmp", "tiff", "tif", "webp", "svg"]
    private static let media: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "aiff"]
    private static let text: Set<String> = ["txt", "json", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "yaml", "yml", "toml", "sh", "zsh", "log", "csv", "xml", "rs", "go", "c", "h", "cpp", "java", "kt", "rb", "sql", "env", "gitignore", "lock"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14).padding(.trailing, 5)
                Text(url.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.trailing, 6)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isMarkdown, isSmall {
                    Button { editingMarkdown.toggle() } label: {
                        Image(systemName: editingMarkdown ? "doc.richtext" : "pencil")
                            .foregroundStyle(editingMarkdown ? Color.accent : Color.secondary)
                    }
                    .help(editingMarkdown ? "Show rendered" : "Edit the markdown")
                }
                if isText {
                    Button { wrapLines.toggle() } label: {
                        Image(systemName: "arrow.turn.down.left")
                            .foregroundStyle(wrapLines ? Color.accent : Color.secondary)
                    }
                    .help(wrapLines ? "Don't wrap lines" : "Wrap lines")
                }
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open with default app")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .help("Close the file")
                }
            }
            .panelHeader()

            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: url) { _, _ in editingMarkdown = false }
    }

    private var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    /// Under 1 MB, so it can be read and laid out whole on the main thread. Sized through
    /// symlinks, since String(contentsOf:) follows them.
    private var isSmall: Bool {
        let size = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize
        return (size ?? .max) < 1_000_000
    }

    private var isText: Bool {
        isMarkdown || Self.text.contains(url.pathExtension.lowercased()) || url.lastPathComponent.hasPrefix(".")
    }

    /// Whether a file opens as text in the editor: a text type, under the size limit, sized
    /// through symlinks. Tests check this where the view tree no longer carries the text.
    static func previewsAsText(_ url: URL) -> Bool {
        let preview = FilePreview(url: url)
        return preview.isText && preview.isSmall && !images.contains(url.pathExtension.lowercased())
    }

    @ViewBuilder
    private var content: some View {
        let ext = url.pathExtension.lowercased()
        if isMarkdown, isSmall, !editingMarkdown {
            MarkdownView(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "", wrapCode: wrapLines)
        } else if isText, isSmall, !Self.images.contains(ext) {
            // Editable in place: small changes and ⌘S, with the agent's edits showing up live.
            FileEditorPane(url: url, wrap: wrapLines, theme: theme).id(url)
        } else if Self.images.contains(ext), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
        } else if Self.media.contains(ext) {
            PlayerView(url: url)
        } else if ext == "pdf" {
            PDFKitView(url: url)
        } else if Self.text.contains(ext) || url.lastPathComponent.hasPrefix("."), isSmall,
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            // Vertical-only scrolling offers the text the panel's width, so it wraps.
            ScrollView(wrapLines ? .vertical : [.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            QuickLookView(url: url)
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// AppKit's player. SwiftUI's VideoPlayer aborts in a SwiftPM build: AVKit isn't linked
/// for it, so its AVPlayerView superclass is missing at runtime.
struct PlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

/// System Quick Look for everything else (gif animation, Office files, fonts, …).
struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as QLPreviewItem }
    }
}

// MARK: - Markdown

/// Renders Markdown using Foundation's parser: block structure from presentation intents,
/// inline styles (bold, italic, code, links) straight from the attributed string.
struct MarkdownView: View {
    let text: String
    var wrapCode = false

    private struct Block: Identifiable {
        let id: Int
        let text: AttributedString
        let intent: PresentationIntent?
    }

    private var blocks: [Block] {
        guard let attributed = try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return [Block(id: 0, text: AttributedString(text), intent: nil)]
        }
        var result: [Block] = []
        for run in attributed.runs[\.presentationIntent] {
            var piece = AttributedString(attributed[run.1])
            piece.presentationIntent = nil
            if let last = result.last, last.intent == run.0 {
                result[result.count - 1] = Block(id: last.id, text: last.text + piece, intent: last.intent)
            } else {
                result.append(Block(id: result.count, text: piece, intent: run.0))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in render(block) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        let components = block.intent?.components ?? []
        if let header = components.compactMap({ c -> Int? in if case .header(let level) = c.kind { return level } else { return nil } }).first {
            Text(block.text)
                .font(.system(size: [22, 18, 15, 13, 12, 12][min(header, 6) - 1], weight: .bold))
                .padding(.top, header <= 2 ? 6 : 2)
        } else if components.contains(where: { if case .codeBlock = $0.kind { return true } else { return false } }) {
            let code = Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
            Group {
                if wrapCode {
                    code.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal) { code }
                }
            }
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        } else if let item = components.compactMap({ c -> Int? in if case .listItem(let ordinal) = c.kind { return ordinal } else { return nil } }).first {
            let ordered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
            let depth = components.filter { if case .listItem = $0.kind { return true } else { return false } }.count
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordered ? "\(item)." : "•").foregroundStyle(.secondary)
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth - 1) * 16)
        } else if components.contains(where: { if case .blockQuote = $0.kind { return true } else { return false } }) {
            HStack(spacing: 8) {
                Rectangle().fill(.secondary).frame(width: 3)
                Text(block.text).foregroundStyle(.secondary)
            }
        } else if components.contains(where: { if case .thematicBreak = $0.kind { return true } else { return false } }) {
            Divider()
        } else {
            Text(block.text)
        }
    }
}
