import Foundation

/// What Claude Code or Codex has set up, read from their files: for the transcript view's
/// overviews of MCP servers, plugins, skills, agents, hooks and permissions, which the terminal
/// otherwise shows in dialogs. Changes go through the agents' own command lines, or, for
/// permission rules, the settings files Claude Code reads.
public enum AgentConfig {
    public struct Row: Equatable, Encodable {
        public var name: String
        public var detail: String
        public var note: String
        /// "on", "off" or "" for the dot in front of the row.
        public var state: String = ""
        /// What the panel can do to this row: login, logout, remove, enable, disable, uninstall.
        public var actions: [String] = []
        /// What the action needs: a scope, a plugin id with scope, or a settings file.
        public var arg: String = ""

        public init(name: String, detail: String, note: String, state: String = "", actions: [String] = [], arg: String = "") {
            self.name = name; self.detail = detail; self.note = note; self.state = state; self.actions = actions; self.arg = arg
        }
    }

    public struct Overview: Equatable, Encodable {
        public var title: String
        public var summary: String
        public var rows: [Row]
        /// The Claude Code command that manages this, for the button.
        public var command: String
        /// Which add form the page offers: "mcp" or "permission".
        public var form: String?
        /// Which overview this is, so an action can rebuild it.
        public var kind: String = ""
        /// What to say when there are no rows, instead of "Nothing configured."
        public var empty: String?
        /// One extra button in the header, and the action it posts.
        public var actionID: String?
        public var actionLabel: String?

        public init(title: String, summary: String, rows: [Row], command: String, form: String? = nil, kind: String = "", empty: String? = nil,
                    actionID: String? = nil, actionLabel: String? = nil) {
            self.title = title; self.summary = summary; self.rows = rows; self.command = command; self.form = form; self.kind = kind
            self.empty = empty; self.actionID = actionID; self.actionLabel = actionLabel
        }
    }

    /// Claude Code's user-scope MCP servers, as configured: name and its config object.
    public static func claudeUserServers() -> [(name: String, server: [String: Any])] {
        let servers = json("\(home)/.claude.json")?["mcpServers"] as? [String: Any] ?? [:]
        return servers.sorted { $0.key < $1.key }.compactMap { name, value in (value as? [String: Any]).map { (name, $0) } }
    }

    private static var home: String { NSHomeDirectory() }

    private static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static let commands: Set<String> = ["mcp", "plugins", "plugin", "skills", "agents", "hooks", "permissions", "commands", "status", "version", "account"]

    public static func hasOverview(for command: String) -> Bool { commands.contains(command) }

    public static func overview(for command: String, project: String, provider: SessionProvider = .claude) -> Overview? {
        if provider == .codex { return codexOverview(for: command, project: project) }
        var overview: Overview?
        switch command {
        case "mcp": overview = mcp(project: project)
        case "plugins", "plugin": overview = plugins(project: project)
        case "skills": overview = skills(project: project)
        case "agents": overview = agents(project: project)
        case "hooks": overview = hooks(project: project)
        case "permissions": overview = permissions(project: project)
        case "commands": overview = commands(project: project)
        case "status", "version", "account": overview = status()
        default: return nil
        }
        overview?.kind = command == "plugin" ? "plugins" : command
        return overview
    }

    // MARK: Claude Code's own defaults

    public struct ClaudeDefaults {
        public var model: String?
        /// A default effort saved with /effort, when there is one.
        public var effort: String?
        /// Per-model effort from the Model settings.
        public var effortByModel: [String: String]
    }

    private static var defaultsCache: (at: Date, value: ClaudeDefaults)?

    /// The model and effort Claude Code starts with when omux passes none: from its settings file,
    /// read at most every half minute since the chips ask on every redraw.
    public static func claudeDefaults() -> ClaudeDefaults {
        if let cached = defaultsCache, Date().timeIntervalSince(cached.at) < 30 { return cached.value }
        let settings = json("\(home)/.claude/settings.json") ?? [:]
        var byModel: [String: String] = [:]
        for (model, value) in settings["modelSettings"] as? [String: Any] ?? [:] {
            if let effort = (value as? [String: Any])?["effortLevel"] as? String { byModel[model] = effort }
        }
        let value = ClaudeDefaults(model: settings["model"] as? String,
                                   effort: settings["effortLevel"] as? String ?? ProcessInfo.processInfo.environment["CLAUDE_CODE_EFFORT_LEVEL"],
                                   effortByModel: byModel)
        defaultsCache = (Date(), value)
        return value
    }

    // MARK: Status

    /// Claude Code's installed version and the account it's signed in as, from its own files.
    public static func status() -> Overview {
        var rows: [Row] = []
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.local/share/claude/versions")) ?? []
        let newest = versions.filter { $0.first?.isNumber == true }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
        rows.append(Row(name: "Claude Code", detail: newest ?? "version unknown", note: "installed", state: "on"))
        if let account = json("\(home)/.claude.json")?["oauthAccount"] as? [String: Any] {
            rows.append(Row(name: "account", detail: account["emailAddress"] as? String ?? "", note: account["fullName"] as? String ?? "", state: "on"))
            let plan = [account["planDisplayName"] as? String, account["organizationType"] as? String].compactMap { $0 }.joined(separator: " · ")
            rows.append(Row(name: "plan", detail: plan, note: account["organizationRateLimitTier"] as? String ?? "", state: "on"))
            if let org = account["organizationName"] as? String { rows.append(Row(name: "organization", detail: org, note: account["organizationRole"] as? String ?? "", state: "on")) }
        } else {
            rows.append(Row(name: "account", detail: "not signed in", note: "", state: "off"))
        }
        return Overview(title: "Claude Code", summary: "Version and account, from Claude Code's files. /status in the terminal shows the live session.",
                        rows: rows, command: "/status", kind: "status")
    }

    // MARK: Codex

    /// Codex keeps MCP servers in ~/.codex/config.toml, skills and prompts in folders, hooks in
    /// hooks.json, and approvals as config keys. No plugins or custom agents.
    public static func codexOverview(for command: String, project: String) -> Overview? {
        let codex = "\(home)/.codex"
        switch command {
        case "mcp":
            var rows: [Row] = []
            for (name, table) in tomlTables(prefix: "mcp_servers.", in: "\(codex)/config.toml") {
                let url = table["url"]
                let command = [table["command"] ?? "", table["args"] ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                let off = table["enabled"] == "false"
                rows.append(Row(name: name, detail: url.map { "http " + $0 } ?? command, note: "user", state: off ? "off" : "on",
                                actions: (url != nil ? ["login", "logout"] : []) + ["remove"], arg: "user"))
            }
            let claudeCount = claudeUserServers().count
            var overview = Overview(title: "MCP servers", summary: rows.isEmpty ? "Codex has none configured." : "\(rows.filter { $0.state == "on" }.count) enabled of \(rows.count) configured in ~/.codex/config.toml. Changes apply to sessions started afterwards.",
                                    rows: rows, command: "/mcp", form: "mcp", kind: "mcp")
            overview.empty = "Codex keeps its own list of MCP servers in ~/.codex/config.toml, separate from Claude Code's" + (claudeCount > 0 ? ", so Claude Code's \(claudeCount) aren't here until they're added to Codex." : ".")
            if claudeCount > 0 {
                overview.actionID = "mcp-import"
                overview.actionLabel = "Copy Claude Code's servers"
            }
            return overview
        case "skills":
            var rows: [Row] = []
            for (root, source) in [("\(codex)/skills", "user"), ("\(project)/.codex/skills", "project"), ("\(project)/.agents/skills", "project")] {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
                for name in names.sorted() where FileManager.default.fileExists(atPath: "\(root)/\(name)/SKILL.md") {
                    rows.append(Row(name: name, detail: frontmatter("\(root)/\(name)/SKILL.md", key: "description") ?? "", note: source, state: "on"))
                }
            }
            return Overview(title: "Skills", summary: "\(rows.count) available to Codex.", rows: rows, command: "/skills", kind: "skills")
        case "hooks":
            var rows: [Row] = []
            for (file, source) in [("\(codex)/hooks.json", "user"), ("\(project)/.codex/hooks.json", "project")] {
                guard let hooks = json(file)?["hooks"] as? [String: Any] else { continue }
                for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
                    for group in value as? [[String: Any]] ?? [] {
                        let matcher = group["matcher"] as? String ?? ""
                        for hook in group["hooks"] as? [[String: Any]] ?? [] {
                            var command = (hook["command"] as? String ?? hook["type"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                            if command.count > 140 { command = String(command.prefix(140)) + "…" }
                            rows.append(Row(name: event + (matcher.isEmpty ? "" : " · " + matcher), detail: command, note: source, state: "on"))
                        }
                    }
                }
            }
            return Overview(title: "Hooks", summary: rows.isEmpty ? "No hooks configured." : "\(rows.count) hooks.", rows: rows, command: "/hooks", kind: "hooks")
        case "permissions":
            let config = tomlTopLevel(in: "\(codex)/config.toml")
            var rows: [Row] = []
            rows.append(Row(name: "approval policy", detail: config["approval_policy"] ?? "default", note: "config.toml", state: "on"))
            rows.append(Row(name: "sandbox", detail: config["sandbox_mode"] ?? "default", note: "config.toml", state: "on"))
            for (path, table) in tomlTables(prefix: "projects.", in: "\(codex)/config.toml") where path == project {
                rows.append(Row(name: "project trust", detail: table["trust_level"] ?? "", note: "config.toml", state: "on"))
            }
            return Overview(title: "Approvals and sandbox", summary: "Codex decides with an approval policy and a sandbox mode; /approvals changes them for the session.",
                            rows: rows, command: "/approvals", kind: "permissions")
        case "commands":
            var rows: [Row] = []
            if let names = try? FileManager.default.contentsOfDirectory(atPath: "\(codex)/prompts") {
                for name in names.sorted() where name.hasSuffix(".md") {
                    rows.append(Row(name: "/prompts:" + name.dropLast(3), detail: frontmatter("\(codex)/prompts/\(name)", key: "description") ?? "", note: "user", state: "on"))
                }
            }
            return Overview(title: "Custom prompts", summary: "\(rows.count) in ~/.codex/prompts.", rows: rows, command: "/prompts", kind: "commands")
        case "plugins", "plugin":
            return Overview(title: "Plugins", summary: "Codex has no plugin system; skills and MCP servers cover it.", rows: [], command: "/mcp", kind: "plugins")
        case "agents":
            return Overview(title: "Agents", summary: "Codex has no custom agent definitions; its subagents are built in.", rows: [], command: "/status", kind: "agents")
        default:
            return nil
        }
    }

    /// Tables `[<prefix><name>]` in a TOML file, each as flat string values. Enough for Codex's config:
    /// quoted strings, numbers, booleans and arrays of strings; nothing nested.
    private static func tomlTables(prefix: String, in path: String) -> [(String, [String: String])] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [(String, [String: String])] = []
        var current: (String, [String: String])?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { result.append(current) }
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if header.hasPrefix(prefix) {
                    var name = String(header.dropFirst(prefix.count))
                    if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                    current = (name, [:])
                } else {
                    current = nil
                }
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            current?.1[key] = tomlValue(String(line[line.index(after: equals)...]))
        }
        if let current { result.append(current) }
        return result
    }

    /// Keys before the first table header.
    private static func tomlTopLevel(in path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            values[line[..<equals].trimmingCharacters(in: .whitespaces)] = tomlValue(String(line[line.index(after: equals)...]))
        }
        return values
    }

    private static func tomlValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            return value.dropFirst().dropLast().split(separator: ",").map { tomlValue(String($0)) }.joined(separator: " ")
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { return String(value.dropFirst().dropLast()) }
        return value
    }

    // MARK: Actions, through the agent's own command line

    /// `claude <arguments>` or `codex <arguments>`, run with the login shell's PATH. Returns success and the output.
    /// Runs the agent's CLI. `pty` gives it a terminal, for commands that refuse to run without
    /// one, such as `claude mcp login`, which opens the browser and waits for the callback.
    public static func run(_ arguments: [String], tool: String = "claude", timeout: TimeInterval = 180, pty: Bool = false) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                let command = tool == "codex" ? "codex" : "claude"
                process.arguments = ["-lc", pty ? "exec /usr/bin/script -q /dev/null \(command) \"$@\"" : "exec \(command) \"$@\"", tool] + arguments
                var environment = ProcessInfo.processInfo.environment
                environment["CI"] = "1"
                environment["PATH"] = ShellPath.current
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: (false, "Couldn't run claude: \(error.localizedDescription)")); return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus == 0, text))
            }
        }
    }

    public static func validName(_ name: String) -> Bool {
        name.range(of: #"^[\w.-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// Adds or removes a permission rule in a settings file, keeping everything else in it.
    public static func editPermission(kind: String, rule: String, file: String, add: Bool) -> String? {
        guard ["allow", "deny", "ask"].contains(kind), !rule.isEmpty, rule.count <= 500, !rule.contains("\n") else { return "Invalid rule" }
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file) {
            // A file that exists but doesn't parse is left alone rather than replaced.
            guard let parsed = json(file) else { return "\((file as NSString).lastPathComponent) isn't valid JSON, so it wasn't changed" }
            settings = parsed
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var rules = permissions[kind] as? [String] ?? []
        if add { if !rules.contains(rule) { rules.append(rule) } } else { rules.removeAll { $0 == rule } }
        permissions[kind] = rules
        settings["permissions"] = permissions
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether a path is one of the settings files the permissions overview reads.
    public static func isSettingsFile(_ path: String, project: String) -> Bool {
        settingsFiles(project: project).contains { $0.path == path }
    }

    public static func settingsFile(scope: String, project: String) -> String {
        switch scope {
        case "project": return "\(project)/.claude/settings.json"
        case "local": return "\(project)/.claude/settings.local.json"
        default: return "\(home)/.claude/settings.json"
        }
    }

    // MARK: MCP

    public static func mcp(project: String) -> Overview {
        var rows: [Row] = []
        let config = json("\(home)/.claude.json") ?? [:]
        let projectConfig = (config["projects"] as? [String: Any])?[project] as? [String: Any] ?? [:]
        let disabled = Set(projectConfig["disabledMcpjsonServers"] as? [String] ?? [])
        func add(_ servers: [String: Any], scope: String, arg: String) {
            for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                guard let server = value as? [String: Any] else { continue }
                let off = disabled.contains(name) || server["disabled"] as? Bool == true
                let remote = server["url"] != nil
                rows.append(Row(name: name, detail: transport(of: server), note: scope, state: off ? "off" : "on",
                                actions: (remote ? ["login", "logout"] : []) + ["remove"], arg: arg))
            }
        }
        add(config["mcpServers"] as? [String: Any] ?? [:], scope: "user", arg: "user")
        add(projectConfig["mcpServers"] as? [String: Any] ?? [:], scope: "project (local)", arg: "local")
        add(json("\(project)/.mcp.json")?["mcpServers"] as? [String: Any] ?? [:], scope: ".mcp.json", arg: "project")
        for plugin in installedPlugins(project: project) where plugin.enabled {
            for file in ["\(plugin.path)/.mcp.json", "\(plugin.path)/mcp.json"] {
                guard let servers = json(file)?["mcpServers"] as? [String: Any] else { continue }
                for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                    guard let server = value as? [String: Any] else { continue }
                    rows.append(Row(name: "\(plugin.shortName):\(name)", detail: transport(of: server), note: "plugin", state: "on"))
                }
            }
        }
        let on = rows.filter { $0.state == "on" }.count
        return Overview(title: "MCP servers", summary: "\(on) enabled of \(rows.count) configured. Changes apply to sessions started afterwards.",
                        rows: rows, command: "/mcp", form: "mcp", kind: "mcp")
    }

    /// One server's live state, from `claude mcp list`.
    public struct Health: Equatable {
        /// "on" connected, "ask" needs sign-in, "off" failed or disabled.
        public var state: String
        public var note: String
        public var target: String
    }

    /// Asks the CLI to connect to every server, the way a new session would, and reads what it
    /// says: connected, needs authentication, or failed with the reason. Takes a few seconds,
    /// since it starts the stdio servers. Keyed by server name as Claude Code shows it.
    public static func mcpHealth() async -> [String: Health] {
        parseMCPHealth(await run(["mcp", "list"], timeout: 90).output)
    }

    /// `name: target - ✔ Connected`, `! Needs authentication`, or `✘ Failed to connect — reason`.
    public static func parseMCPHealth(_ output: String) -> [String: Health] {
        var health: [String: Health] = [:]
        let pattern = try! NSRegularExpression(pattern: #"^(.+?): (.*?) - (✔|✓|!|⚠|✘|✗) (.*)$"#)
        for line in output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func group(_ i: Int) -> String { Range(match.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            let name = group(1), target = group(2), mark = group(3), rest = group(4)
            let state: String, note: String
            switch mark {
            case "✔", "✓": state = "on"; note = "Connected"
            case "!", "⚠": state = "ask"; note = "Needs sign-in"
            default:
                state = "off"
                let reason = rest.replacingOccurrences(of: "Failed to connect", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " —-–"))
                note = reason.isEmpty ? "Failed to connect" : "Failed: " + (reason.count > 140 ? String(reason.prefix(140)) + "…" : reason)
            }
            health[name] = Health(state: state, note: note, target: target.replacingOccurrences(of: #" \((HTTP|SSE|stdio)\)$"#, with: "", options: .regularExpression))
        }
        return health
    }

    /// The configured servers with their live state folded in, plus the ones only the CLI
    /// knows: claude.ai connectors, plugin servers and built-ins. Sign-in and reconnect go
    /// through the session's own /mcp dialog, so they apply to the running session.
    public static func mcp(project: String, health: [String: Health]) -> Overview {
        var overview = mcp(project: project)
        var seen: Set<String> = []
        for index in overview.rows.indices {
            let row = overview.rows[index]
            seen.insert(row.name)
            guard let live = health[row.name] else { continue }
            let scope = row.note
            overview.rows[index].state = row.state == "off" ? "off" : live.state
            overview.rows[index].note = row.state == "off" ? "\(scope) · Disabled" : "\(scope) · \(live.note)"
            overview.rows[index].actions = Self.actions(for: live.state, remote: row.detail.hasPrefix("http") || row.detail.hasPrefix("sse"), configured: !row.arg.isEmpty)
        }
        for (name, live) in health.sorted(by: { $0.key < $1.key }) where !seen.contains(name) {
            let source = name.hasPrefix("claude.ai ") ? "claude.ai" : name.hasPrefix("plugin:") ? "plugin" : "built-in"
            overview.rows.append(Row(name: name, detail: live.target, note: "\(source) · \(live.note)", state: live.state,
                                     actions: Self.actions(for: live.state, remote: live.target.hasPrefix("http"), configured: false)))
        }
        let on = overview.rows.filter { $0.state == "on" }.count
        let ask = overview.rows.filter { $0.state == "ask" }.count
        let off = overview.rows.filter { $0.state == "off" }.count
        var parts = ["\(on) connected"]
        if ask > 0 { parts.append("\(ask) need\(ask == 1 ? "s" : "") sign-in") }
        if off > 0 { parts.append("\(off) failed or disabled") }
        overview.summary = parts.joined(separator: " · ") + ". Sign in and reconnect act in this session; adding and removing apply to sessions started afterwards."
        return overview
    }

    private static func actions(for state: String, remote: Bool, configured: Bool) -> [String] {
        var actions: [String] = []
        switch state {
        case "ask": actions.append("login")
        case "off": actions.append("reconnect")
        default: if remote { actions.append("logout") }
        }
        if configured { actions.append("remove") }
        return actions
    }

    private static func transport(of server: [String: Any]) -> String {
        if let url = server["url"] as? String { return (server["type"] as? String ?? "http") + " " + url }
        let command = server["command"] as? String ?? ""
        let args = (server["args"] as? [String] ?? []).joined(separator: " ")
        return [command, args].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Plugins

    public struct Plugin {
        public var name: String
        public var marketplace: String
        public var version: String
        public var scope: String
        public var path: String
        public var enabled: Bool
        public var shortName: String { name }
    }

    public static func installedPlugins(project: String) -> [Plugin] {
        let registry = json("\(home)/.claude/plugins/installed_plugins.json")?["plugins"] as? [String: Any] ?? [:]
        let settings = json("\(home)/.claude/settings.json") ?? [:]
        let enabled = settings["enabledPlugins"] as? [String: Bool] ?? [:]
        var result: [Plugin] = []
        for (key, value) in registry.sorted(by: { $0.key < $1.key }) {
            let entries = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
            for entry in entries {
                let scope = entry["scope"] as? String ?? "user"
                if scope == "project", let path = entry["projectPath"] as? String, path != project { continue }
                let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
                result.append(Plugin(name: parts.first ?? key, marketplace: parts.count > 1 ? parts[1] : "",
                                     version: entry["version"] as? String ?? "", scope: scope,
                                     path: entry["installPath"] as? String ?? "", enabled: enabled[key] ?? true))
            }
        }
        return result
    }

    public static func plugins(project: String) -> Overview {
        let list = installedPlugins(project: project)
        let rows = list.map { plugin in
            Row(name: plugin.name, detail: plugin.marketplace, note: [plugin.version, plugin.scope].filter { !$0.isEmpty }.joined(separator: " · "),
                state: plugin.enabled ? "on" : "off",
                actions: [plugin.enabled ? "disable" : "enable", "uninstall"],
                arg: "\(plugin.name)@\(plugin.marketplace)|\(plugin.scope)")
        }
        return Overview(title: "Plugins", summary: "\(list.filter(\.enabled).count) enabled of \(list.count) installed.", rows: rows, command: "/plugins")
    }

    // MARK: Skills, agents, commands

    private static func frontmatter(_ path: String, key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8),
              text.hasPrefix("---") else { return nil }
        for line in text.split(separator: "\n").dropFirst().prefix(40) {
            if line.hasPrefix("---") { break }
            if line.hasPrefix("\(key):") {
                var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                return value.count > 160 ? String(value.prefix(160)) + "…" : value
            }
        }
        return nil
    }

    public static func skills(project: String) -> Overview {
        var rows: [Row] = []
        func add(root: String, source: String, prefix: String = "") {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
            for name in names.sorted() {
                let file = "\(root)/\(name)/SKILL.md"
                guard FileManager.default.fileExists(atPath: file) else { continue }
                rows.append(Row(name: prefix + name, detail: frontmatter(file, key: "description") ?? "", note: source, state: "on"))
            }
        }
        add(root: "\(home)/.claude/skills", source: "user")
        add(root: "\(project)/.claude/skills", source: "project")
        for plugin in installedPlugins(project: project) where plugin.enabled {
            add(root: "\(plugin.path)/skills", source: "plugin " + plugin.name, prefix: plugin.name + ":")
        }
        return Overview(title: "Skills", summary: "\(rows.count) available. Invoke one with /name.", rows: rows, command: "/skills")
    }

    public static func agents(project: String) -> Overview {
        var rows: [Row] = []
        func add(root: String, source: String, prefix: String = "") {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
            for name in names.sorted() where name.hasSuffix(".md") {
                let file = "\(root)/\(name)"
                rows.append(Row(name: prefix + (frontmatter(file, key: "name") ?? String(name.dropLast(3))),
                                detail: frontmatter(file, key: "description") ?? "", note: source, state: "on"))
            }
        }
        add(root: "\(home)/.claude/agents", source: "user")
        add(root: "\(project)/.claude/agents", source: "project")
        for plugin in installedPlugins(project: project) where plugin.enabled {
            add(root: "\(plugin.path)/agents", source: "plugin " + plugin.name, prefix: plugin.name + ":")
        }
        return Overview(title: "Agents", summary: rows.isEmpty ? "No custom agents. Built-in ones such as general-purpose and Explore are always available." : "\(rows.count) custom, plus the built-in ones.",
                        rows: rows, command: "/agents")
    }

    public static func commands(project: String) -> Overview {
        var rows: [Row] = []
        func add(root: String, source: String) {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { return }
            for case let path as String in enumerator where path.hasSuffix(".md") {
                let name = String(path.dropLast(3)).replacingOccurrences(of: "/", with: ":")
                rows.append(Row(name: "/" + name, detail: frontmatter("\(root)/\(path)", key: "description") ?? "", note: source, state: "on"))
            }
        }
        add(root: "\(home)/.claude/commands", source: "user")
        add(root: "\(project)/.claude/commands", source: "project")
        return Overview(title: "Custom commands", summary: "\(rows.count) defined.", rows: rows.sorted { $0.name < $1.name }, command: "/help")
    }

    // MARK: Hooks and permissions

    private static func settingsFiles(project: String) -> [(path: String, source: String)] {
        [("\(home)/.claude/settings.json", "user"), ("\(home)/.claude/settings.local.json", "user local"),
         ("\(project)/.claude/settings.json", "project"), ("\(project)/.claude/settings.local.json", "project local")]
    }

    public static func hooks(project: String) -> Overview {
        var rows: [Row] = []
        for file in settingsFiles(project: project) {
            guard let hooks = json(file.path)?["hooks"] as? [String: Any] else { continue }
            for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
                for group in value as? [[String: Any]] ?? [] {
                    let matcher = group["matcher"] as? String ?? ""
                    for hook in group["hooks"] as? [[String: Any]] ?? [] {
                        var command = hook["command"] as? String ?? hook["type"] as? String ?? ""
                        command = command.replacingOccurrences(of: "\n", with: " ")
                        if command.count > 140 { command = String(command.prefix(140)) + "…" }
                        rows.append(Row(name: event + (matcher.isEmpty ? "" : " · " + matcher), detail: command, note: file.source, state: "on"))
                    }
                }
            }
        }
        return Overview(title: "Hooks", summary: rows.isEmpty ? "No hooks configured." : "\(rows.count) hooks across \(Set(rows.map { $0.name.split(separator: " ").first ?? "" }).count) events.",
                        rows: rows, command: "/hooks")
    }

    public static func permissions(project: String) -> Overview {
        var rows: [Row] = []
        var mode: String?
        for file in settingsFiles(project: project) {
            guard let permissions = json(file.path)?["permissions"] as? [String: Any] else { continue }
            if let m = permissions["defaultMode"] as? String { mode = m }
            for (kind, state) in [("allow", "on"), ("deny", "off"), ("ask", "")] {
                for rule in permissions[kind] as? [String] ?? [] {
                    rows.append(Row(name: kind, detail: rule, note: file.source, state: state, actions: ["remove"], arg: file.path))
                }
            }
        }
        let config = json("\(home)/.claude.json") ?? [:]
        let projectConfig = (config["projects"] as? [String: Any])?[project] as? [String: Any] ?? [:]
        for rule in projectConfig["allowedTools"] as? [String] ?? [] {
            rows.append(Row(name: "allow", detail: rule, note: "project (local)", state: "on"))
        }
        let allow = rows.filter { $0.name == "allow" }.count
        let deny = rows.filter { $0.name == "deny" }.count
        return Overview(title: "Permissions", summary: "\(allow) allowed, \(deny) denied" + (mode.map { ", default mode \($0)" } ?? "") + ". Rules match tool names and patterns.",
                        rows: rows, command: "/permissions", form: "permission")
    }
}
