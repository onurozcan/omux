import AppKit
import SwiftUI

struct DiffNote: Identifiable, Hashable {
    let id = UUID()
    let path: String
    /// The diff row the note sits under.
    let lineIndex: Int
    let lineNumber: Int?
    var text: String
}

/// Files marked as viewed, by path, with what their change looked like then: its kind, its
/// line counts and the blob id of its content. The mark goes when any of them moves.
enum ViewedMarks {
    static func signature(_ file: ChangedFile, blob: String?) -> String {
        "\(file.statusLetter) \(file.added.map(String.init) ?? "-") \(file.removed.map(String.init) ?? "-") \(blob ?? "")"
    }

    /// The marks still true for `files`. A file whose content wasn't read this time keeps its mark;
    /// so does every file when the listing failed, and a file left out of a truncated one.
    static func kept(_ marks: [String: String], files: [ChangedFile], blobs: [String: String]?,
                     ok: Bool = true, truncated: Bool = false) -> [String: String] {
        guard ok else { return marks }
        let listed = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return marks.filter { path, mark in
            guard let file = listed[path] else { return truncated }
            let blob = blobs?[path]
            if blob == nil, file.status != .deleted { return true }
            return mark == signature(file, blob: blob)
        }
    }

    /// "2/5 viewed", or nil while nothing is marked.
    static func label(viewed: Int, of total: Int) -> String? {
        viewed > 0 ? "\(viewed)/\(total) viewed" : nil
    }
}

/// The selected session's changes, kept fresh while its folder changes.
@MainActor
final class Changes: ObservableObject {
    static let shared = Changes()

    @Published private(set) var tabID: UUID?
    @Published private(set) var files: [ChangedFile] = []
    @Published private(set) var isRepo = false
    /// What the files are compared with, for display: the base branch or HEAD.
    @Published private(set) var baseName = "HEAD"
    /// Review notes per session, until they're sent.
    @Published var notes: [UUID: [DiffNote]] = [:]
    /// Files marked as viewed per session, by path, with `ViewedMarks.signature` at the time.
    /// Kept across relaunches, and only for files still listed.
    @Published private(set) var viewed: [UUID: [String: String]] = Changes.loadViewed()
    private static let viewedKey = "changesViewed"
    /// Files of this session marked a moment ago, shown checked while their content is read.
    @Published private var pendingViewed: Set<String> = []

    private(set) var dir: String?
    private var worktree: Worktree?
    private var base: String?
    private var watcher: FolderWatcher?
    /// Commits and resets touch only HEAD and the index, which can be outside `dir`.
    private var gitWatcher: FolderWatcher?
    private var remotePoll: Timer?
    private var refreshing = false
    private var again = false

    /// Follows the selected session. Folders outside a repo aren't watched, so a session
    /// in the home folder costs nothing.
    func track(tabID: UUID?, dir: String?, worktree: Worktree?) {
        guard tabID != self.tabID || dir != self.dir || worktree != self.worktree else { return }
        self.tabID = tabID
        self.dir = dir
        self.worktree = worktree
        files = []
        pendingViewed = []
        base = nil
        remotePoll?.invalidate(); remotePoll = nil
        watcher = nil
        gitWatcher = nil
        isRepo = false
        baseName = worktree?.base ?? "HEAD"
        if let dir { detectRepo(dir) }
    }

    private func detectRepo(_ dir: String) {
        Task.detached {
            let inRepo = Git.topLevel(dir) != nil
            let gitDir = inRepo ? Git.gitDirectory(dir) : nil
            await MainActor.run {
                guard self.dir == dir, inRepo, !self.isRepo else { return }
                self.isRepo = true
                // A folder on another machine tells nothing when it changes: look every few
                // seconds while its session is the one in view.
                if RemotePath.isRemote(dir) {
                    self.remotePoll?.invalidate()
                    self.remotePoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        Task { @MainActor in if let self, self.dir == dir { self.refresh() } }
                    }
                    self.refresh()
                    return
                }
                self.watcher = FolderWatcher(path: dir) { [weak self] in self?.refresh() }
                if let gitDir, !gitDir.hasPrefix(dir + "/") {
                    self.gitWatcher = FolderWatcher(path: gitDir) { [weak self] in self?.refresh() }
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard let dir else { return }
        guard isRepo else { detectRepo(dir); return }
        if refreshing { again = true; return }
        refreshing = true
        let worktree = self.worktree
        let tabID = self.tabID
        let marked = tabID.flatMap { viewed[$0] } ?? [:]
        Task.detached {
            let base = Git.diffBase(dir: dir, worktree: worktree)
            let listing = Git.changedListing(dir: dir, base: base)
            let files = listing.files
            // Read only while something is marked, and only for the marked files.
            let blobs = marked.isEmpty ? nil
                : Git.blobIDs(dir: dir, paths: files.filter { marked[$0.path] != nil && $0.status != .deleted }.map(\.path))
            await MainActor.run {
                self.refreshing = false
                if self.dir == dir {
                    self.base = base
                    if self.files != files { self.files = files }
                    if let tabID, tabID == self.tabID, let marks = self.viewed[tabID] {
                        let kept = ViewedMarks.kept(marks, files: files, blobs: blobs, ok: listing.ok, truncated: listing.truncated)
                        if kept != marks { self.setViewed(kept, for: tabID) }
                    }
                    if worktree != nil, let tabID = self.tabID { DiffStatMonitor.shared.update(tabID, files.totals) }
                }
                if self.again || self.dir != dir {
                    self.again = false
                    self.refresh()
                }
            }
        }
    }

    func diff(for file: ChangedFile) async -> [DiffLine] {
        guard let dir else { return [] }
        let base = self.base
        return await Task.detached { Git.diff(dir: dir, base: base, file: file) }.value
    }

    func isViewed(_ file: ChangedFile) -> Bool {
        pendingViewed.contains(file.path) || tabID.flatMap { viewed[$0]?[file.path] } != nil
    }

    /// Marks the file as viewed, or takes the mark off. A second click while its content is
    /// still being read takes the mark back too.
    func toggleViewed(_ file: ChangedFile) {
        guard let tabID, let dir else { return }
        if isViewed(file) {
            pendingViewed.remove(file.path)
            var marks = viewed[tabID] ?? [:]
            marks[file.path] = nil
            setViewed(marks, for: tabID)
            return
        }
        pendingViewed.insert(file.path)
        Task.detached {
            let blob = file.status == .deleted ? nil : Git.blobIDs(dir: dir, paths: [file.path])?[file.path]
            await MainActor.run {
                guard self.tabID == tabID, self.dir == dir, self.pendingViewed.remove(file.path) != nil,
                      blob != nil || file.status == .deleted else { return }
                var marks = self.viewed[tabID] ?? [:]
                marks[file.path] = ViewedMarks.signature(file, blob: blob)
                self.setViewed(marks, for: tabID)
            }
        }
    }

    /// Drops a closed session's marks.
    func forgetViewed(tab id: UUID) {
        if viewed[id] != nil { setViewed([:], for: id) }
    }

    private func setViewed(_ marks: [String: String], for tabID: UUID) {
        viewed[tabID] = marks.isEmpty ? nil : marks
        let kept = viewed.reduce(into: [String: [String: String]]()) { $0[$1.key.uuidString] = $1.value }
        if kept.isEmpty { UserDefaults.standard.removeObject(forKey: Self.viewedKey) } else { UserDefaults.standard.set(kept, forKey: Self.viewedKey) }
    }

    private static func loadViewed() -> [UUID: [String: String]] {
        (UserDefaults.standard.dictionary(forKey: viewedKey) as? [String: [String: String]] ?? [:])
            .reduce(into: [UUID: [String: String]]()) { if let id = UUID(uuidString: $1.key) { $0[id] = $1.value } }
    }

    func setNote(_ text: String, for line: DiffLine, path: String) {
        guard let tabID else { return }
        var list = notes[tabID] ?? []
        list.removeAll { $0.path == path && $0.lineIndex == line.index }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list.append(DiffNote(path: path, lineIndex: line.index, lineNumber: line.number, text: trimmed))
        }
        notes[tabID] = list
    }

    func removeNote(_ note: DiffNote) {
        guard let tabID else { return }
        notes[tabID]?.removeAll { $0.id == note.id }
    }

    /// Types every note into the session as one message and submits it.
    func sendNotes() {
        guard let tabID, let list = notes[tabID], !list.isEmpty else { return }
        let body = list.map { note in
            // The name comes from the repository and can hold newlines, which Return would run.
            "- \(CheckLog.plain(note.path))\(note.lineNumber.map { ":\($0)" } ?? ""): \(note.text)"
        }.joined(separator: "\n")
        // Kept when the session isn't running, so they can be sent once it is.
        guard Store.shared.sendText("Review notes on your changes:\n" + body, to: tabID, submit: true) else {
            Store.showError("Couldn't send the notes", "The session isn't running. Start it and send them again.")
            return
        }
        notes[tabID] = []
    }
}

/// Lines changed in each worktree session, for the sidebar. The selected session updates
/// with its Changes panel, the others about once a minute and on coming back to omux.
@MainActor
final class DiffStatMonitor: ObservableObject {
    static let shared = DiffStatMonitor()

    @Published private(set) var stats: [UUID: DiffStat] = [:]

    private let queue = DispatchQueue(label: "omux.diffstats", qos: .utility)
    private var polling = false
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in DiffStatMonitor.shared.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DiffStatMonitor.shared.poll() }
        }
        DispatchQueue.main.async { self.poll() }
    }

    func update(_ id: UUID, _ stat: DiffStat) {
        if stats[id] != stat { stats[id] = stat }
    }

    func poll() {
        guard !polling else { return }
        let store = Store.shared
        let sessions = store.allTabs.compactMap { entry -> (id: UUID, dir: String, worktree: Worktree)? in
            guard let worktree = entry.tab.worktree, let dir = store.directory(of: entry.tab),
                  FileManager.default.fileExists(atPath: dir) else { return nil }
            return (entry.tab.id, dir, worktree)
        }
        polling = true
        queue.async {
            var found: [UUID: DiffStat] = [:]
            for session in sessions {
                let base = Git.diffBase(dir: session.dir, worktree: session.worktree)
                found[session.id] = Git.changedFiles(dir: session.dir, base: base).totals
            }
            DispatchQueue.main.async {
                self.polling = false
                if found != self.stats { self.stats = found }
            }
        }
    }
}

// MARK: - Panel

struct ChangesPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var changes = Changes.shared
    let theme: Theme
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true
    @State private var selected: String?
    @FocusState private var listFocused: Bool
    @State private var lines: [DiffLine] = []
    @State private var editing: Int?
    @State private var draft = ""

    private var file: ChangedFile? { changes.files.first { $0.path == selected } }
    private var notes: [DiffNote] { store.selectedTabID.flatMap { changes.notes[$0] } ?? [] }
    private var worktree: Worktree? { store.selectedTab?.worktree }

    var body: some View {
        Group {
            if !changes.isRepo {
                placeholder("Not a Git repository", "Changes show up for sessions inside a Git repository.")
            } else if changes.files.isEmpty {
                VStack(spacing: 0) {
                    placeholder("No changes", "Nothing differs from \(changes.baseName) yet.")
                    footer
                }
            } else {
                VSplitView {
                    diffArea
                        .frame(minHeight: 160)
                        .layoutPriority(1)
                    VStack(spacing: 0) {
                        listHeader
                        fileList
                        footer
                    }
                    .frame(minHeight: 170, idealHeight: 220)
                }
            }
        }
        .background(Color(nsColor: theme.background))
        .onAppear { changes.refresh(); pickFile() }
        .onChange(of: changes.files) { _, _ in pickFile(); reload() }
        .onChange(of: selected) { _, _ in editing = nil; reload() }
        .onChange(of: changes.tabID) { _, _ in selected = nil; editing = nil; pickFile() }
        // Folders outside a repo aren't watched, but a session can run git init in one.
        .task(id: changes.isRepo) {
            while !changes.isRepo, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                changes.refresh()
            }
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        EmptyState(icon: "plusminus", title: title, detail: detail)
    }

    private func pickFile() {
        if selected == nil || !changes.files.contains(where: { $0.path == selected }) {
            selected = changes.files.first?.path
        }
    }

    private func reload() {
        guard let file else { lines = []; return }
        Task {
            let result = await changes.diff(for: file)
            if file.path == selected { lines = result }
        }
    }

    // MARK: Diff

    private var diffArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let file {
                    Text(file.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(file.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Stat(added: file.added, removed: file.removed)
                    Button { open(file) } label: { Image(systemName: "arrow.up.forward.square") }
                        .help("Open with default app")
                } else {
                    Spacer()
                }
            }
            .panelHeader()

            ScrollView(wrapLines ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        row(line)
                        if let note = notes.first(where: { $0.path == selected && $0.lineIndex == line.index }), editing != line.index {
                            noteBubble(note, line: line)
                        }
                        if editing == line.index { editor(line) }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var wholeFileNew: Bool { file?.status == .added || file?.status == .untracked }

    private func row(_ line: DiffLine) -> some View {
        let (sign, signColor, background): (String, Color, Color) = {
            switch line.kind {
            // A file that is new from top to bottom needs no tint on every line: the gutter says it.
            case .added: return ("+", Palette.done, wholeFileNew ? .clear : Palette.done.opacity(0.09))
            case .removed: return ("−", Palette.error, Palette.error.opacity(0.09))
            case .hunk: return ("", .secondary, Color.primary.opacity(0.045))
            case .info: return ("", .secondary, .clear)
            case .context: return ("", .secondary, .clear)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 6)
            Text(sign)
                .foregroundStyle(signColor)
                .frame(width: 12, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .info ? .secondary : .primary)
                .fixedSize(horizontal: !wrapLines, vertical: true)
            Spacer(minLength: 8)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
        .overlay(alignment: .leading) {
            if line.kind == .added || line.kind == .removed { Rectangle().fill(signColor.opacity(0.8)).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard line.kind != .hunk, line.kind != .info else { return }
            draft = notes.first { $0.path == selected && $0.lineIndex == line.index }?.text ?? ""
            editing = line.index
        }
                    .help("Click to leave a note for this session")
    }

    private func noteBubble(_ note: DiffNote, line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble").foregroundStyle(.yellow)
            Text(note.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { changes.removeNote(note) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove note")
        }
        .font(.system(size: 12))
        .padding(8)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 54)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .onTapGesture { draft = note.text; editing = line.index }
    }

    private func editor(_ line: DiffLine) -> some View {
        NoteEditor(draft: $draft) {
            if let selected { changes.setNote(draft, for: line, path: selected) }
            editing = nil
        } cancel: {
            editing = nil
        }
        .padding(.leading, 54)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }

    // MARK: Files

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("\(changes.files.count) changed file\(changes.files.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold))
            Text("vs \(changes.baseName)").font(.caption2).foregroundStyle(.tertiary)
            if let viewed = ViewedMarks.label(viewed: changes.files.filter(changes.isViewed).count, of: changes.files.count) {
                Text(viewed).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { changes.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            if let dir = changes.dir {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open folder in Finder")
            }
        }
        .panelHeader()
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
        List {
            ForEach(changes.files) { file in
                let viewed = changes.isViewed(file)
                let toggle = viewed ? "Unmark as viewed" : "Mark as viewed"
                SoftRow(selected: selected == file.path) { selected = file.path; listFocused = true } content: {
                HStack(spacing: 6) {
                    Button { changes.toggleViewed(file) } label: {
                        // The whole box takes the click, not only the glyph's outline.
                        Image(systemName: viewed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .frame(width: 14, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(toggle)
                    .accessibilityLabel(toggle)
                    Text(file.statusLetter)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(file.statusColor)
                        .frame(width: 12)
                    Text(file.name).lineLimit(1).foregroundStyle(viewed ? .secondary : .primary)
                    Text(file.folder)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if notes.contains(where: { $0.path == file.path }) {
                        Image(systemName: "text.bubble").foregroundStyle(.yellow).font(.caption)
                    }
                    Stat(added: file.added, removed: file.removed)
                    ChangeBar(added: file.added ?? 0, removed: file.removed ?? 0)
                }
                }
                .id(file.path)
                .contextMenu {
                    Button("Open") { open(file) }
                    Button("Reveal in Finder") { reveal(file) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: theme.background))
        // The arrow keys walk the files, as they did with the system's selection.
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) { step(-1, proxy) }
        .onKeyPress(.downArrow) { step(1, proxy) }
        }
    }

    private func step(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let paths = changes.files.map(\.path)
        guard !paths.isEmpty else { return .ignored }
        let at = selected.flatMap { paths.firstIndex(of: $0) } ?? (by > 0 ? -1 : paths.count)
        let next = paths[min(max(at + by, 0), paths.count - 1)]
        selected = next
        proxy.scrollTo(next)
        return .handled
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !notes.isEmpty {
                Image(systemName: "text.bubble").foregroundStyle(.yellow)
                Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
                Button("Send to \(store.selectedProvider == .codex ? "Codex" : "Claude")") { changes.sendNotes() }
                    .help("Types the notes into the session and sends them")
            } else if !changes.files.isEmpty {
                Text("Click a line to leave a note").foregroundStyle(.secondary)
            }
            Spacer()
            if let id = store.selectedTabID, let activity = store.gitActivity[id] {
                ProgressView().controlSize(.small)
                Text(activity).foregroundStyle(.secondary)
            } else if let worktree, let id = store.selectedTabID {
                Menu {
                    Button("Merge into \(worktree.base)") { store.mergeWorktree(id) }
                } label: {
                    Text("Create PR")
                } primaryAction: {
                    store.createPullRequest(id)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("Push \(worktree.branch) and open a pull request into \(worktree.base)")
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color(nsColor: theme.background))
        .overlay(alignment: .top) { Hairline() }
    }

    private func url(_ file: ChangedFile) -> URL? {
        // Nothing here to open or reveal when the folder is on another machine.
        guard let dir = changes.dir, !RemotePath.isRemote(dir) else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent(file.path)
    }

    private func open(_ file: ChangedFile) {
        if let url = url(file) { NSWorkspace.shared.open(url) }
    }

    private func reveal(_ file: ChangedFile) {
        if let url = url(file) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

/// The note field under a diff line: Return adds, Escape cancels.
private struct NoteEditor: View {
    @Binding var draft: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Review note", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand(perform: cancel)
            Button("Add", action: save)
            Button("Cancel", action: cancel)
        }
        .controlSize(.small)
        .onAppear { focused = true }
    }
}

/// "+12 −3" in green and red.
/// Five small squares split between added and removed, so a file's balance shows at a glance.
struct ChangeBar: View {
    let added: Int
    let removed: Int

    var body: some View {
        let total = added + removed
        // Whichever side has anything gets at least one square.
        let green = added == 0 ? 0 : removed == 0 ? 5 : min(4, max(1, Int((Double(added) / Double(total) * 5).rounded())))
        let red = removed == 0 ? 0 : 5 - green
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < green ? Palette.done : index < green + red ? Palette.error : Color.primary.opacity(0.12))
                    .frame(width: 4, height: 7)
            }
        }
        .help("\(added) added, \(removed) removed")
    }
}

struct Stat: View {
    let added: Int?
    let removed: Int?

    var body: some View {
        HStack(spacing: 4) {
            if let added, added > 0 { Text("+\(added)").foregroundStyle(Palette.done) }
            if let removed, removed > 0 { Text("−\(removed)").foregroundStyle(Palette.error) }
            if added == nil { Text("binary").foregroundStyle(.tertiary) }
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

extension ChangedFile {
    var statusLetter: String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .untracked: return "U"
        }
    }

    var statusColor: Color {
        switch status {
        case .modified: return Palette.needs
        case .added, .untracked: return Palette.done
        case .deleted: return Palette.error
        }
    }
}
