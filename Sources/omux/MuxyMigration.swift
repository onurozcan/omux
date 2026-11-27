import Foundation

/// Bringing a Muxy setup over to omux: the projects it lists and the few settings omux has a
/// counterpart for. Muxy's own files are only ever read.
///
/// Muxy has kept its state in two shapes, both under Application Support:
/// - `Muxy/`: one JSON file per subject (`projects.json`, `settings.json`).
/// - `Muxy 2/`, `Muxy Beta/`: `desktop-state.json` with every project in it, and `settings.toml`.
enum MuxyMigration {
    enum Format: String {
        /// `projects.json` and `settings.json`.
        case legacy
        /// `desktop-state.json` and `settings.toml`.
        case desktopState
    }

    /// One Muxy folder found on this Mac.
    struct Source: Identifiable, Hashable {
        /// The folder's name, as the user knows the app: "Muxy", "Muxy 2", "Muxy Beta".
        let name: String
        let directory: URL
        let format: Format
        var id: String { directory.path }
    }

    /// A Muxy project, reduced to what omux keeps of a project.
    struct Project: Hashable {
        var name: String
        /// The project's folder, as an absolute path.
        var directory: String
        var pinned = false
        var lastActive: Date?
        var useWorktrees = false
        /// The project's picture as Muxy stored it, in any image format.
        var logo: Data?
    }

    /// The Muxy settings omux has a place for; nil where Muxy had none or omux can't use the value.
    struct Settings: Equatable {
        /// `Prefs.fontFamily`: the terminal font.
        var fontFamily: String?
        /// `Prefs.fontSize`.
        var fontSize: Double?
        /// `Prefs.confirmQuit`.
        var confirmQuit: Bool?
        /// `Prefs.notifySound`: one of `Notifier.sounds`.
        var notifySound: String?
        /// `Prefs.openLinksIn`: "omux" or "system".
        var openLinksIn: String?

        /// How many of them are set.
        var count: Int {
            [fontFamily != nil, fontSize != nil, confirmQuit != nil, notifySound != nil, openLinksIn != nil].filter { $0 }.count
        }
    }

    /// What one source holds.
    struct Found {
        let source: Source
        /// Local projects in Muxy's order; no home project, no worktree checkouts, no remote ones.
        var projects: [Project]
        var settings: Settings
    }

    /// Which of a source's projects would be added to omux, and why the others would not.
    struct Plan: Equatable {
        var add: [Project] = []
        /// Already a project in omux, by folder.
        var alreadyThere = 0
        /// The folder is gone from this Mac.
        var missingFolder = 0
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The Muxy folders under `support` that hold something to read, the newest shape first.
    static func sources(in support: URL = applicationSupport) -> [Source] {
        [("Muxy 2", Format.desktopState), ("Muxy Beta", .desktopState), ("Muxy", .legacy)].compactMap { name, format in
            let directory = support.appendingPathComponent(name, isDirectory: true)
            let main = format == .legacy ? "projects.json" : "desktop-state.json"
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(main).path) else { return nil }
            return Source(name: name, directory: directory, format: format)
        }
    }

    /// Reads a source. nil when its files can't be read or are of a version this doesn't know.
    static func read(_ source: Source) -> Found? {
        let directory = source.directory
        var settings = Settings()
        let projects: [Project]
        switch source.format {
        case .legacy:
            guard let list = json(directory.appendingPathComponent("projects.json")) as? [Any] else { return nil }
            projects = legacyProjects(list, logos: directory.appendingPathComponent("logos", isDirectory: true))
            let stored = json(directory.appendingPathComponent("settings.json")) as? [String: Any] ?? [:]
            settings.confirmQuit = stored["muxy.app.confirmQuit"] as? Bool
            if let sound = stored["muxy.notifications.sound"] as? String, sound != "Default", Notifier.sounds.contains(sound) {
                settings.notifySound = sound
            }
        case .desktopState:
            // Inferred from what Muxy wrote, not from anything it documents: every field may be
            // missing, and a version this hasn't seen may mean something else entirely.
            guard let state = json(directory.appendingPathComponent("desktop-state.json")) as? [String: Any],
                  state["version"] as? Int == 3 else { return nil }
            projects = (state["projects"] as? [Any] ?? []).compactMap(desktopProject)
            if let toml = try? String(contentsOf: directory.appendingPathComponent("settings.toml"), encoding: .utf8),
               openersURL(in: toml) == "system.browser" {
                settings.openLinksIn = "system"
            }
        }
        if let conf = try? String(contentsOf: directory.appendingPathComponent("ghostty.conf"), encoding: .utf8) {
            (settings.fontFamily, settings.fontSize) = font(in: conf)
        }
        return Found(source: source, projects: projects, settings: settings)
    }

    private static func json(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// `projects.json`, in Muxy's order. Dates are what a default `JSONEncoder` writes: seconds
    /// since 2001. The home project isn't in the file; Muxy adds it when it loads.
    private static func legacyProjects(_ list: [Any], logos: URL) -> [Project] {
        let read = list.enumerated().compactMap { index, item -> (order: Int, index: Int, project: Project)? in
            guard let item = item as? [String: Any], let path = item["path"] as? String, path.hasPrefix("/"),
                  isNull(item["remoteWorkspaceID"]), isNull(item["remoteDeviceID"]) else { return nil }
            var project = Project(name: name(item["name"], path: path), directory: path)
            project.pinned = item["isPinned"] as? Bool ?? false
            project.useWorktrees = item["worktreesEnabled"] as? Bool ?? false
            project.lastActive = (item["lastActiveAt"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
            if let file = item["logo"] as? String, !file.isEmpty, file == (file as NSString).lastPathComponent {
                project.logo = try? Data(contentsOf: logos.appendingPathComponent(file))
            }
            return (item["sortOrder"] as? Int ?? 0, index, project)
        }
        return read.sorted { ($0.order, $0.index) < ($1.order, $1.index) }.map(\.project)
    }

    /// One project of `desktop-state.json`, or nil for what omux has no counterpart for: the
    /// home project, a worktree checkout or anything else with a kind or a parent, and one
    /// whose folder can't be made out. The folder and the picture are stored as arrays of bytes.
    private static func desktopProject(_ item: Any) -> Project? {
        guard let item = item as? [String: Any], item["home"] as? Bool != true,
              isNull(item["kind"]), isNull(item["parent_id"]),
              let path = bytes(item["directory"]).flatMap({ String(data: $0, encoding: .utf8) }), path.hasPrefix("/") else { return nil }
        var project = Project(name: name(item["name"], path: path), directory: path)
        project.logo = bytes(item["logo"]).flatMap { $0.isEmpty ? nil : $0 }
        return project
    }

    private static func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private static func bytes(_ value: Any?) -> Data? {
        guard let numbers = value as? [Int], numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return Data(numbers.map { UInt8($0) })
    }

    private static func name(_ value: Any?, path: String) -> String {
        let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (path as NSString).lastPathComponent : name
    }

    /// The `url` key of the `[openers]` table, as a quoted string; enough of TOML for that one value.
    private static func openersURL(in toml: String) -> String? {
        var table = ""
        for line in toml.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.hasPrefix("[[") ? "" : String(line.dropFirst().prefix { $0 != "]" }).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard table == "openers", let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\"") else { return nil }
            let rest = value.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<close])
        }
        return nil
    }

    /// The font in a Ghostty config. A repeated `font-family` adds fallbacks there, so the first
    /// is the one in use; a repeated `font-size` overrides, so the last is.
    private static func font(in conf: String) -> (family: String?, size: Double?) {
        var family: String?, size: Double?
        for line in conf.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "="), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == value.last, value.first == "\"" || value.first == "'" { value = String(value.dropFirst().dropLast()) }
            switch line[..<equals].trimmingCharacters(in: .whitespaces) {
            case "font-family" where family == nil && !value.isEmpty: family = value
            case "font-size": size = Double(value).flatMap { Fonts.sizes.contains($0) ? $0 : nil }
            default: break
            }
        }
        return (family, size)
    }

    /// Sorts projects into those to add and those to leave. A project is left when omux already
    /// has one in the same folder (`Store.samePath`), when the same folder came earlier in
    /// `projects`, or when `folderExists` says the folder is gone.
    static func plan(_ projects: [Project], existing: [TabGroup],
                     folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan {
        var plan = Plan()
        // A project on another machine with the same path is a different folder.
        var seen = existing.filter { !$0.isRemote }.compactMap(\.directory)
        for project in projects where !project.directory.isEmpty {
            if seen.contains(where: { Store.samePath($0, project.directory) }) {
                plan.alreadyThere += 1
            } else if !folderExists(project.directory) {
                plan.missingFolder += 1
            } else {
                plan.add.append(project)
            }
            seen.append(project.directory)
        }
        return plan
    }

    /// omux projects for the ones to add, each with one session that hasn't started.
    /// `saveLogo` stores a picture and returns its file name, as `ProjectIcons.save` does
    /// after `ProjectIcons.squarePNG`; nil leaves the project with its initials.
    static func groups(for projects: [Project], saveLogo: (Data) -> String?) -> [TabGroup] {
        projects.map { project in
            var group = TabGroup(name: project.name, directory: project.directory, tabs: [TabItem(name: "Session 1")])
            group.pinned = project.pinned
            group.lastActive = project.lastActive
            group.useWorktrees = project.useWorktrees
            group.icon = project.logo.flatMap(saveLogo)
            return group
        }
    }

    /// Writes the settings that are set into `defaults` and returns how many it wrote.
    static func apply(_ settings: Settings, to defaults: UserDefaults = .standard) -> Int {
        let values: [(String, Any?)] = [(Prefs.fontFamily, settings.fontFamily), (Prefs.fontSize, settings.fontSize),
                                        (Prefs.confirmQuit, settings.confirmQuit), (Prefs.notifySound, settings.notifySound),
                                        (Prefs.openLinksIn, settings.openLinksIn)]
        var written = 0
        for case let (key, value?) in values {
            defaults.set(value, forKey: key)
            written += 1
        }
        return written
    }
}
