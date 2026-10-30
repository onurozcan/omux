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

    private(set) var dir: String?
    private var worktree: Worktree?
    private var base: String?
    private var watcher: FolderWatcher?
    private var refreshing = false
    private var again = false

    var totals: (added: Int, removed: Int) {
        files.reduce((0, 0)) { ($0.0 + ($1.added ?? 0), $0.1 + ($1.removed ?? 0)) }
    }

    /// Follows the selected session. Folders outside a repo aren't watched, so a session
    /// in the home folder costs nothing.
    func track(tabID: UUID?, dir: String?, worktree: Worktree?) {
        guard tabID != self.tabID || dir != self.dir || worktree != self.worktree else { return }
        self.tabID = tabID
        self.dir = dir
        self.worktree = worktree
        files = []
        base = nil
        watcher = nil
        isRepo = false
        baseName = worktree?.base ?? "HEAD"
        guard let dir else { return }
        Task.detached {
            let inRepo = Git.topLevel(dir) != nil
            await MainActor.run {
                guard self.dir == dir, inRepo else { return }
                self.isRepo = true
                self.watcher = FolderWatcher(path: dir) { [weak self] in self?.refresh() }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard let dir, isRepo else { return }
        if refreshing { again = true; return }
        refreshing = true
        let worktree = self.worktree
        Task.detached {
            let base = Git.diffBase(dir: dir, worktree: worktree)
            let files = Git.changedFiles(dir: dir, base: base)
            await MainActor.run {
                self.refreshing = false
                if self.dir == dir {
                    self.base = base
                    if self.files != files { self.files = files }
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
            "- \(note.path)\(note.lineNumber.map { ":\($0)" } ?? ""): \(note.text)"
        }.joined(separator: "\n")
        Store.shared.sendText("Review notes on your changes:\n" + body, to: tabID, submit: true)
        notes[tabID] = []
    }
}

// MARK: - Panel

struct ChangesPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var changes = Changes.shared
    let theme: Theme
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true
    @State private var selected: String?
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
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }

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

    private func row(_ line: DiffLine) -> some View {
        let (sign, signColor, background): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", .green, Color.green.opacity(0.13))
            case .removed: return ("−", .red, Color.red.opacity(0.13))
            case .hunk: return ("", .secondary, Color.blue.opacity(0.08))
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
            Spacer()
            Button { changes.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            if let dir = changes.dir {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open folder in Finder")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }

    private var fileList: some View {
        List(selection: $selected) {
            ForEach(changes.files) { file in
                HStack(spacing: 6) {
                    Text(file.statusLetter)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(file.statusColor)
                        .frame(width: 12)
                    Text(file.name).lineLimit(1)
                    Text(file.folder)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if notes.contains(where: { $0.path == file.path }) {
                        Image(systemName: "text.bubble").foregroundStyle(.yellow).font(.caption)
                    }
                    Stat(added: file.added, removed: file.removed)
                }
                .tag(file.path)
                .contextMenu {
                    Button("Open") { open(file) }
                    Button("Reveal in Finder") { reveal(file) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: theme.chrome))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !notes.isEmpty {
                Image(systemName: "text.bubble").foregroundStyle(.yellow)
                Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
                Button("Send to \(store.selectedProvider.agentName)") { changes.sendNotes() }
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
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }

    private func url(_ file: ChangedFile) -> URL? {
        changes.dir.map { URL(fileURLWithPath: $0).appendingPathComponent(file.path) }
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
struct Stat: View {
    let added: Int?
    let removed: Int?

    var body: some View {
        HStack(spacing: 4) {
            if let added, added > 0 { Text("+\(added)").foregroundStyle(.green) }
            if let removed, removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
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
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        }
    }
}
