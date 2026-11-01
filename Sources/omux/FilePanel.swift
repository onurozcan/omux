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
    @AppStorage(Prefs.filesByDate) private var byDate = false
    @AppStorage(Prefs.filesBrowserCollapsed) private var browserCollapsed = false
    @State private var rootNode: FileNode?
    @State private var watcher: FolderWatcher?
    @State private var version = 0
    @State private var selected: String?
    @State private var previewURL: URL?

    var body: some View {
        VSplitView {
            Group {
                if let agent = store.openAgent, agent.tabID == store.selectedTabID {
                    AgentTranscriptView(ref: agent).id(agent.agentID)
                } else if let ref = store.openCodexAgent, ref.tabID == store.selectedTabID {
                    CodexAgentTranscriptView(ref: ref).id(ref.agent.id)
                } else if let url = previewURL {
                    FilePreview(url: url)
                } else {
                    Text("Select a file to preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)
            .background(Color(nsColor: theme.background))
            .layoutPriority(1)

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
                        Picker("", selection: $byDate) {
                            Text("Name").tag(false)
                            Text("Date").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button { NSWorkspace.shared.open(root) } label: { Image(systemName: "arrow.up.forward.square") }
                        .help("Open folder in Finder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }

                if !browserCollapsed {
                    List(selection: $selected) {
                        if !store.mentionedPaths.isEmpty {
                            Section("Mentioned in session") {
                                ForEach(store.mentionedPaths.reversed(), id: \.self) { path in
                                    let url = URL(fileURLWithPath: path)
                                    Label {
                                        HStack(spacing: 4) {
                                            Text(url.lastPathComponent).lineLimit(1)
                                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                        }
                                    } icon: {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                            .resizable()
                                            .frame(width: 14, height: 14)
                                    }
                                    .tag(path)
                                }
                            }
                        }
                        Section(root.lastPathComponent) {
                        if let rootNode {
                            OutlineGroup(rootNode.children ?? [], id: \.id, children: \.children) { node in
                                Label {
                                    Text(node.name).lineLimit(1)
                                } icon: {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                                        .resizable()
                                        .frame(width: 14, height: 14)
                                }
                                .tag(node.id)
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
                    }
                    .id(version)
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minHeight: browserCollapsed ? 28 : 80, idealHeight: browserCollapsed ? 28 : 180, maxHeight: browserCollapsed ? 28 : .infinity)
        }
        .background(Color(nsColor: theme.chrome))
        .onAppear { load(); showRequested(); store.scanMentionedPaths() }
        .onChange(of: root) { _, _ in load() }
        .onChange(of: store.previewRequest) { _, _ in showRequested() }
        .onChange(of: store.selectedTabID) { _, _ in store.scanMentionedPaths() }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in store.scanMentionedPaths() }
        .onChange(of: byDate) { _, _ in refresh() }
        .onChange(of: selected) { _, path in
            guard let path else { return }
            store.openAgent = nil
            store.openCodexAgent = nil
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                previewURL = URL(fileURLWithPath: path)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { previewURL = url }
            }
            return true
        }
    }

    private func showRequested() {
        guard let path = store.previewRequest else { return }
        store.openAgent = nil
        store.openCodexAgent = nil
        previewURL = URL(fileURLWithPath: path)
        selected = path
        store.previewRequest = nil
    }

    private func load() {
        rootNode = FileNode(url: root, isDirectory: true)
        selected = nil
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
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true

    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "bmp", "tiff", "tif", "webp", "svg"]
    private static let media: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "aiff"]
    private static let text: Set<String> = ["txt", "json", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "yaml", "yml", "toml", "sh", "zsh", "log", "csv", "xml", "rs", "go", "c", "h", "cpp", "java", "kt", "rb", "sql", "env", "gitignore", "lock"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isText {
                    Button { wrapLines.toggle() } label: {
                        Image(systemName: "arrow.turn.down.left")
                            .foregroundStyle(wrapLines ? Color.accentColor : Color.secondary)
                    }
                    .help(wrapLines ? "Don't wrap lines" : "Wrap lines")
                }
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open with default app")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }

            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    @ViewBuilder
    private var content: some View {
        let ext = url.pathExtension.lowercased()
        if isMarkdown, isSmall {
            MarkdownView(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "", wrapCode: wrapLines)
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
