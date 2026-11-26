import Foundation
import OmuxCLIProtocol

/// The rules behind the `omux` tool, kept free of the Store so they can be tested.
enum CLIScope {
    /// Finds `target` among `sessions` by id, then by exact name, then by name ignoring case.
    /// nil is the caller. A name shared by several sessions is refused.
    static func resolve(_ target: String?, caller: UUID, sessions: [(id: UUID, name: String)]) -> Result<UUID, CLIUsageError> {
        guard let target = target?.trimmingCharacters(in: .whitespaces), !target.isEmpty else { return .success(caller) }
        if let id = UUID(uuidString: target) {
            return sessions.contains { $0.id == id } ? .success(id) : .failure(CLIUsageError("no session \(target) in this project"))
        }
        for exact in [true, false] {
            let matches = sessions.filter { exact ? $0.name == target : $0.name.caseInsensitiveCompare(target) == .orderedSame }
            if matches.count == 1 { return .success(matches[0].id) }
            if matches.count > 1 { return .failure(CLIUsageError("\(matches.count) sessions are named \(target); use an id from omux list")) }
        }
        return .failure(CLIUsageError("no session named \(target) in this project"))
    }

    /// Whether `directory` is one of `roots` or inside one, after symlinks and `..` are resolved.
    static func allowed(directory: String, within roots: [String]) -> Bool {
        let dir = resolved(directory)
        return roots.map(resolved).contains { root in dir == root || dir.hasPrefix(root + "/") }
    }

    private static func resolved(_ path: String) -> String {
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }

    /// What a session may do to another: read any session of its project, steer only its own.
    static func maySteer(_ target: UUID, caller: UUID, children: Set<UUID>) -> Bool {
        target == caller || children.contains(target)
    }
}

extension Store {
    /// Whether sessions get the `omux` tool at all. Settings › Sessions.
    static var cliEnabled: Bool { UserDefaults.standard.object(forKey: Prefs.cliEnabled) as? Bool ?? true }

    /// Environment that lets a session reach the tool: its id, its token, the socket, the PATH.
    func cliEnvironment(for tabID: UUID, path: String) -> [String: String] {
        guard Self.cliEnabled else { return ["PATH": path] }
        CommandServer.shared.start()
        guard let socket = CommandServer.shared.socketPath else { return ["PATH": path] }
        var env = ["OMUX_TAB_ID": tabID.uuidString, "OMUX_TOKEN": CommandServer.shared.token(for: tabID.uuidString), "OMUX_SOCKET": socket, "PATH": path]
        if let bin = CommandServer.binDirectory { env["PATH"] = bin + ":" + path }
        return env
    }

    /// Answers a request the server has already checked the token of.
    func handleCLI(_ request: CLIRequest) -> CLIResponse {
        guard Self.cliEnabled else { return .failure("the command line tool is turned off in Settings › Sessions") }
        guard let caller = UUID(uuidString: request.from), let group = group(containing: caller), let callerTab = tab(caller) else {
            return .failure("this session isn't known to omux any more")
        }
        let siblings = group.tabs.map { (id: $0.id, name: $0.name) }
        let children = cliChildren[caller] ?? []
        func info(_ id: UUID) -> CLISession? {
            guard let tab = tab(id) else { return nil }
            let rt = runtime[id] ?? TabRuntime(exited: true)
            let state: String
            if rt.exited || terminal(ifRunning: id) == nil { state = "stopped" }
            else if let s = rt.statusState { state = s.rawValue }
            else { state = "running" }
            return CLISession(id: id.uuidString, name: tab.name, provider: provider(of: tab).rawValue, state: state,
                              kind: rt.statusKind, message: rt.statusDetail, directory: rt.cwd ?? directory(of: tab),
                              isSelf: id == caller, isChild: children.contains(id))
        }
        func target() -> Result<UUID, CLIUsageError> { CLIScope.resolve(request.target, caller: caller, sessions: siblings) }

        switch request.command {
        case "list":
            return CLIResponse(ok: true, sessions: group.tabs.compactMap { info($0.id) })
        case "status":
            switch target() {
            case .failure(let e): return .failure(e.message)
            case .success(let id): return CLIResponse(ok: true, session: info(id))
            }
        case "screen":
            switch target() {
            case .failure(let e): return .failure(e.message)
            case .success(let id):
                guard let view = terminal(ifRunning: id) else { return .failure("that session isn't running") }
                let lines = min(max(request.lines ?? CLICommand.defaultScreenLines, 1), CLICommand.maxScreenLines)
                return CLIResponse(ok: true, session: info(id), screen: view.lastLines(lines))
            }
        case "send":
            switch target() {
            case .failure(let e): return .failure(e.message)
            case .success(let id):
                guard CLIScope.maySteer(id, caller: caller, children: children) else {
                    return .failure("a session can only send text to sessions it started with omux new")
                }
                guard let text = request.text, !text.isEmpty else { return .failure("nothing to send") }
                guard text.utf8.count <= 64 << 10 else { return .failure("text over 64 KB; write it to a file and send the path") }
                guard sendText(text, to: id, submit: request.submit ?? false) else { return .failure("that session isn't running") }
                if id != caller, let name = tab(id)?.name {
                    let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(80)
                    Notices.shared.post("\(callerTab.name) → \(name)", detail: String(preview), isError: false)
                }
                return CLIResponse(ok: true, session: info(id))
            }
        case "new":
            let provider = request.provider.flatMap(SessionProvider.init(rawValue:)) ?? callerTab.resolvedProvider(in: group)
            guard [.claude, .codex, .shell].contains(provider) else { return .failure("--provider is claude, codex or shell") }
            let roots = [directory(of: callerTab), group.directory.map { ($0 as NSString).expandingTildeInPath }].compactMap { $0 }
            let dir = request.directory.map { ($0 as NSString).expandingTildeInPath } ?? roots.first
            if let dir {
                guard !roots.isEmpty, CLIScope.allowed(directory: dir, within: roots) else {
                    return .failure("sessions can only be started inside this project's folder")
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return .failure("no folder \(dir)") }
            }
            // Shown in the sidebar: no control characters, one line.
            let name = request.name.map { CheckLog.plain($0.replacingOccurrences(of: "\n", with: " ")).trimmingCharacters(in: .whitespaces) }
            var tab = TabItem(name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "Session \(group.tabs.count + 1)",
                              directory: dir, command: provider.command)
            tab.provider = provider
            addSession(tab, to: group.id, select: false)
            cliChildren[caller, default: []].insert(tab.id)
            Notices.shared.post("\(callerTab.name) started \(tab.name)", detail: "\(provider.label) in \(dir ?? "~")", isError: false)
            return CLIResponse(ok: true, session: info(tab.id))
        case "close":
            switch target() {
            case .failure(let e): return .failure(e.message)
            case .success(let id):
                guard id != caller, children.contains(id) else { return .failure("a session can only close sessions it started with omux new") }
                let name = tab(id)?.name ?? "session"
                closeTab(id)
                Notices.shared.post("\(callerTab.name) closed \(name)", detail: "", isError: false)
                return CLIResponse(ok: true)
            }
        default:
            return .failure("unknown command \(request.command)")
        }
    }
}
