import AppKit
import OmuxCore
import SwiftUI

/// Files of a project on another machine. A folder is listed there when it is opened; a file
/// looked at is copied here first, into the caches, and shown from the copy by the same
/// preview and editor as a local file. Saving the copy sends it back.
enum RemoteFiles {
    struct Entry: Identifiable, Hashable {
        let path: String
        let isDirectory: Bool
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Bigger files than this aren't copied over to be looked at.
    static let maxBytes = 5_000_000

    private static let lock = NSLock()
    /// Where each local copy came from, and how the original was when it was copied.
    nonisolated(unsafe) private static var origins: [String: (host: String, path: String, stamp: String)] = [:]

    static func localURL(host: String, path: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return RemoteHost.mirrorRoot.appendingPathComponent(safe, isDirectory: true).appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    static func origin(of local: URL) -> (host: String, path: String, stamp: String)? {
        lock.lock(); defer { lock.unlock() }
        return origins[local.standardizedFileURL.path]
    }

    private static func remember(_ local: URL, host: String, path: String, stamp: String) {
        lock.lock(); origins[local.standardizedFileURL.path] = (host, path, stamp); lock.unlock()
    }

    /// Script lines that set `$F` to the file there, with `~` meaning that machine's home.
    private static func named(_ path: String) -> String {
        "D=" + Git.quote(path) + "\n" + RemotePath.resolve + "\nF=\"$D\"\n"
    }

    /// The folder's real path there and what is in it: folders first, hidden names and the
    /// usual heaps left out, as in the local tree.
    static func list(host: String, folder: String) async -> Result<(path: String, entries: [Entry]), MachineProblem> {
        let answer = await RemoteMachines.run(RemotePath.entering(folder) + "pwd; ls -1p 2>/dev/null | head -600", on: host)
        if answer.status == 127 { return .failure(MachineProblem(text: "No folder \(folder) on \(host).")) }
        guard answer.status == 0 else { return .failure(MachineProblem(text: RemoteMachines.explain(answer.error, host: host))) }
        var lines = answer.output.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return .failure(MachineProblem(text: "\(host) said nothing.")) }
        let here = lines.removeFirst()
        let entries = lines.compactMap { line -> Entry? in
            let isDirectory = line.hasSuffix("/")
            let name = isDirectory ? String(line.dropLast()) : line
            guard !name.isEmpty, !FileNode.skipped.contains(name) else { return nil }
            return Entry(path: here == "/" ? "/" + name : here + "/" + name, isDirectory: isDirectory)
        }
        return .success((here, entries.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }))
    }

    /// Size and time of the file there, as one word that changes when the file does.
    static func stamp(host: String, path: String) async -> String? {
        let script = named(path) + #"stat -c '%s-%Y' -- "$F" 2>/dev/null || stat -f '%z-%m' -- "$F" 2>/dev/null"#
        let answer = await RemoteMachines.run(script, on: host)
        let stamp = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.status == 0 && !stamp.isEmpty ? stamp : nil
    }

    /// Copies the file here to be looked at. `path` is its full path there.
    static func fetch(host: String, path: String) async -> Result<URL, MachineProblem> {
        let script = named(path) + #"""
        [ -f "$F" ] || exit 5
        [ "$(wc -c < "$F")" -le \#(maxBytes) ] || exit 4
        (stat -c '%s-%Y' -- "$F" 2>/dev/null || stat -f '%z-%m' -- "$F") >&2
        cat -- "$F"
        """#
        let answer = await Task.detached { RemotePath.run(script, on: host, timeout: 20) }.value
        switch answer.status {
        case 0: break
        case 4: return .failure(MachineProblem(text: "\((path as NSString).lastPathComponent) is over \(maxBytes / 1_000_000) MB: too large to look at from here."))
        case 5: return .failure(MachineProblem(text: "No file \(path) on \(host)."))
        default: return .failure(MachineProblem(text: RemoteMachines.explain(answer.error, host: host)))
        }
        let local = localURL(host: host, path: path)
        do {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Unchanged, the copy is left alone: an editor open on it isn't disturbed.
            if (try? Data(contentsOf: local)) != answer.output { try answer.output.write(to: local, options: .atomic) }
        } catch { return .failure(MachineProblem(text: "Couldn't keep a copy of the file: \(error.localizedDescription)")) }
        remember(local, host: host, path: path, stamp: answer.error.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
        return .success(local)
    }

    /// Sends a saved copy back to where it came from, written in place so the file keeps its
    /// permissions. Nothing to do for a file that isn't a copy.
    @MainActor
    static func saved(_ local: URL) {
        guard let origin = origin(of: local) else { return }
        Task {
            let script = named(origin.path) + #"cat > "$F" && (stat -c '%s-%Y' -- "$F" 2>/dev/null || stat -f '%z-%m' -- "$F")"#
            let answer = await RemoteMachines.run(script, on: origin.host, timeout: 20, input: local)
            if answer.status == 0 {
                remember(local, host: origin.host, path: origin.path, stamp: answer.output.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                Notices.shared.post("Couldn't save \(local.lastPathComponent) on \(origin.host)",
                                    detail: "Your changes are in the copy on this Mac only. " + RemoteMachines.explain(answer.error, host: origin.host), isError: true)
            }
        }
    }
}

/// The folders opened and what each holds, for the tree.
@MainActor
final class RemoteTree: ObservableObject {
    let host: String
    @Published private(set) var root: String?
    @Published private(set) var children: [String: [RemoteFiles.Entry]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var problem: String?
    @Published private(set) var loading = false

    init(host: String) { self.host = host }

    func open(_ folder: String) {
        loading = true
        Task {
            switch await RemoteFiles.list(host: host, folder: folder) {
            case .success(let listing):
                root = listing.path; children = [listing.path: listing.entries]; expanded = [listing.path]; problem = nil
            case .failure(let failure):
                problem = failure.text
            }
            loading = false
        }
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder); return }
        expanded.insert(folder)
        if children[folder] == nil { load(folder) }
    }

    private func load(_ folder: String) {
        Task {
            if case .success(let listing) = await RemoteFiles.list(host: host, folder: folder) { children[folder] = listing.entries }
        }
    }

    /// Lists again what is open: a file made or removed there shows.
    func refresh() {
        for folder in expanded { load(folder) }
    }

    /// The tree as rows, each with how deep it sits.
    var rows: [(entry: RemoteFiles.Entry, depth: Int)] {
        guard let root else { return [] }
        var out: [(RemoteFiles.Entry, Int)] = []
        func walk(_ folder: String, _ depth: Int) {
            for entry in children[folder] ?? [] {
                out.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) { walk(entry.path, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }
}

/// The Files tab for a project on another machine.
struct RemoteFilePanel: View {
    @EnvironmentObject var store: Store
    let host: String
    let folder: String
    let theme: Theme
    @StateObject private var tree: RemoteTree
    @State private var selected: String?
    @State private var preview: URL?
    @State private var problem: String?
    @State private var fetching = false

    init(host: String, folder: String, theme: Theme) {
        self.host = host; self.folder = folder; self.theme = theme
        _tree = StateObject(wrappedValue: RemoteTree(host: host))
    }

    var body: some View {
        VSplitView {
            Group {
                if let preview {
                    FilePreview(url: preview).id(preview)
                } else {
                    VStack(spacing: 6) {
                        if fetching { ProgressView().controlSize(.small) }
                        Text(problem ?? (fetching ? "Getting the file from \(host)…" : "Select a file to look at"))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 120)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "network").font(.caption2).foregroundStyle(.tertiary)
                    Text(tree.root.map { ($0 as NSString).lastPathComponent } ?? folder)
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(host).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    if tree.loading { ProgressView().controlSize(.mini) }
                    Button { tree.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("List the folders again")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                if let problem = tree.problem, tree.root == nil {
                    Text(problem).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(tree.rows, id: \.entry.id, selection: $selected) { row in
                        HStack(spacing: 5) {
                            Image(systemName: row.entry.isDirectory ? (tree.expanded.contains(row.entry.path) ? "chevron.down" : "chevron.right") : "circle")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(row.entry.isDirectory ? Color.secondary : Color.clear)
                                .frame(width: 9)
                            Image(systemName: row.entry.isDirectory ? "folder" : "doc").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(row.entry.name).lineLimit(1)
                        }
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .tag(row.entry.path)
                        .contextMenu {
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.entry.path, forType: .string)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minHeight: 80, idealHeight: 200)
        }
        .background(Color(nsColor: theme.chrome))
        .onAppear { tree.open(folder); showRequested() }
        .onChange(of: selected) { _, path in
            guard let path, let row = tree.rows.first(where: { $0.entry.path == path }) else { return }
            if row.entry.isDirectory { tree.toggle(path) } else { show(path) }
        }
        .onChange(of: store.previewRequest) { _, _ in showRequested() }
        // The file may change there while it is open here, an agent editing it: keep the copy fresh.
        .task(id: preview) {
            guard let preview, let origin = RemoteFiles.origin(of: preview) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let now = await RemoteFiles.stamp(host: origin.host, path: origin.path),
                      now != RemoteFiles.origin(of: preview)?.stamp else { continue }
                _ = await RemoteFiles.fetch(host: origin.host, path: origin.path)
            }
        }
    }

    /// A path clicked in the transcript, on that machine.
    private func showRequested() {
        guard let path = store.previewRequest else { return }
        store.previewRequest = nil
        show(path)
    }

    private func show(_ path: String) {
        fetching = true
        problem = nil
        Task {
            switch await RemoteFiles.fetch(host: host, path: path) {
            case .success(let local): preview = local
            case .failure(let failure): preview = nil; problem = failure.text
            }
            fetching = false
        }
    }
}
