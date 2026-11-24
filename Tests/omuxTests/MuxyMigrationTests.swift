import XCTest
@testable import omux

/// Bringing a Muxy setup over: finding its folders, reading both shapes it has stored them in,
/// deciding what to add, and what that becomes in omux.
final class MuxyMigrationTests: XCTestCase {
    /// An Application Support folder of its own for each test.
    private struct Support {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omux-muxy-" + UUID().uuidString)

        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func write(json: Any, _ path: String) throws {
            try write(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), path)
        }

        func read(_ name: String) -> MuxyMigration.Found? {
            MuxyMigration.sources(in: root).first { $0.name == name }.flatMap(MuxyMigration.read)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func bytes(_ text: String) -> [Int] { text.utf8.map(Int.init) }

    func testSourcesAreTheFoldersWithSomethingToReadNewestShapeFirst() throws {
        let support = Support()
        defer { support.remove() }
        XCTAssertEqual(MuxyMigration.sources(in: support.root), [])
        try support.write("[]", "Muxy/projects.json")
        try support.write("{}", "Muxy Beta/desktop-state.json")
        try support.write("", "Muxy 2/settings.toml")
        try support.write("", "Muxy Runtime/leases")
        XCTAssertEqual(MuxyMigration.sources(in: support.root).map(\.name), ["Muxy Beta", "Muxy"], "a folder without its main file is not a source")

        try support.write("{}", "Muxy 2/desktop-state.json")
        let sources = MuxyMigration.sources(in: support.root)
        XCTAssertEqual(sources.map(\.name), ["Muxy 2", "Muxy Beta", "Muxy"])
        XCTAssertEqual(sources.map(\.format), [.desktopState, .desktopState, .legacy])
        XCTAssertEqual(sources.last?.directory.lastPathComponent, "Muxy")
    }

    func testTheOlderShapeKeepsMuxysOrderAndLeavesRemoteProjectsBehind() throws {
        let support = Support()
        defer { support.remove() }
        try support.write(json: [
            ["id": UUID().uuidString, "name": "Second", "path": "/Users/someone/code/api", "sortOrder": 2, "createdAt": 600_000_000,
             "worktreesEnabled": true, "isPinned": false, "logo": "api.png"],
            ["id": UUID().uuidString, "name": "First", "path": "/Users/someone/code/app", "sortOrder": 1, "createdAt": 600_000_000,
             "lastActiveAt": 700_000_000.5, "worktreesEnabled": false, "isPinned": true],
            ["id": UUID().uuidString, "name": "Remote", "path": "/srv/app", "sortOrder": 0, "createdAt": 600_000_000,
             "worktreesEnabled": false, "isPinned": false, "remoteWorkspaceID": UUID().uuidString],
            ["id": UUID().uuidString, "name": "Device", "path": "/srv/web", "sortOrder": 0, "createdAt": 600_000_000,
             "worktreesEnabled": false, "isPinned": false, "remoteDeviceID": UUID().uuidString],
            ["id": UUID().uuidString, "path": "/tmp/unnamed", "sortOrder": 3, "remoteWorkspaceID": NSNull(), "logo": "../escape.png"],
            ["id": UUID().uuidString, "name": "Relative", "path": "code/rel", "sortOrder": 4],
            ["id": UUID().uuidString, "name": "No folder", "sortOrder": 4],
            "not a project",
        ], "Muxy/projects.json")
        try support.write("PNG", "Muxy/logos/api.png")
        try support.write("outside", "escape.png")

        let found = try XCTUnwrap(support.read("Muxy"))
        XCTAssertEqual(found.projects.map(\.name), ["First", "Second", "unnamed"], "by sortOrder; a missing name is the folder's")
        let first = found.projects[0], second = found.projects[1]
        XCTAssertEqual(first.directory, "/Users/someone/code/app")
        XCTAssertTrue(first.pinned)
        XCTAssertFalse(first.useWorktrees)
        XCTAssertEqual(first.lastActive, Date(timeIntervalSinceReferenceDate: 700_000_000.5), "seconds since 2001, as JSONEncoder writes them")
        XCTAssertNil(first.logo)
        XCTAssertTrue(second.useWorktrees)
        XCTAssertNil(second.lastActive)
        XCTAssertEqual(second.logo, Data("PNG".utf8))
        XCTAssertNil(found.projects[2].logo, "a logo name may not reach outside the logos folder")
        XCTAssertEqual(found.settings, MuxyMigration.Settings(), "no settings files, no settings")
    }

    func testTheNewerShapeKeepsOnlyPlainLocalProjects() throws {
        let support = Support()
        defer { support.remove() }
        func project(_ name: Any, _ directory: Any, home: Bool = false, kind: Any = NSNull(), parent: Any = NSNull(), logo: Any = NSNull()) -> [String: Any] {
            ["id": String(repeating: "a", count: 32), "name": name, "directory": directory, "home": home, "kind": kind, "parent_id": parent,
             "logo": logo, "color": "blue", "icon": NSNull(), "server_id": "local", "tabs": []]
        }
        try support.write(json: ["version": 3, "window": [:], "projects": [
            project("Home", bytes("/Users/someone"), home: true),
            project("Web", bytes("/Users/someone/code/web"), logo: [0x89, 0x50, 0x4E, 0x47]),
            project("feature", bytes("/Users/someone/code/web-feature"), kind: "worktree", parent: "b"),
            project("Child", bytes("/Users/someone/code/child"), parent: String(repeating: "b", count: 32)),
            project("Other kind", bytes("/Users/someone/code/other"), kind: "something"),
            project("Too big", [47, 300]),
            project("Not UTF-8", [47, 0xFF, 0xFE]),
            project("Relative", bytes("code/rel")),
            project("As text", "/Users/someone/code/text"),
            project("Ünïcode", bytes("/Users/someone/code/ünï"), logo: []),
            project(NSNull(), bytes("/tmp/nameless")),
            ["id": "c"],
            42,
        ]], "Muxy 2/desktop-state.json")

        let found = try XCTUnwrap(support.read("Muxy 2"))
        XCTAssertEqual(found.projects.map(\.name), ["Web", "Ünïcode", "nameless"], "in the file's order")
        XCTAssertEqual(found.projects.map(\.directory), ["/Users/someone/code/web", "/Users/someone/code/ünï", "/tmp/nameless"])
        XCTAssertEqual(found.projects[0].logo, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertNil(found.projects[1].logo, "an empty picture is none")
        XCTAssertFalse(found.projects[0].pinned)
        XCTAssertNil(found.projects[0].lastActive)
    }

    func testOnlyTheKnownVersionOfTheNewerShapeIsRead() throws {
        let support = Support()
        defer { support.remove() }
        try support.write(json: ["version": 2, "projects": [["name": "Web", "directory": bytes("/tmp/web"), "home": false]]], "Muxy Beta/desktop-state.json")
        try support.write(json: ["projects": []], "Muxy 2/desktop-state.json")
        XCTAssertNil(support.read("Muxy Beta"))
        XCTAssertNil(support.read("Muxy 2"), "no version is not version 3")
        try support.write(json: ["version": 3], "Muxy 2/desktop-state.json")
        XCTAssertEqual(support.read("Muxy 2")?.projects, [], "every field may be missing")
    }

    func testMalformedFilesReadAsNothingRatherThanCrashing() throws {
        let support = Support()
        defer { support.remove() }
        try support.write("[{\"name\": ", "Muxy/projects.json")
        try support.write("not json", "Muxy 2/desktop-state.json")
        try support.write("[]", "Muxy Beta/desktop-state.json")
        XCTAssertNil(support.read("Muxy"))
        XCTAssertNil(support.read("Muxy 2"))
        XCTAssertNil(support.read("Muxy Beta"), "a list where an object belongs")
        try support.write("{\"name\": \"x\"}", "Muxy/projects.json")
        XCTAssertNil(support.read("Muxy"), "an object where a list belongs")

        // A broken settings file costs only the settings.
        try support.write("[]", "Muxy/projects.json")
        try support.write("{oops", "Muxy/settings.json")
        try support.write("\u{0}\u{1}=", "Muxy/ghostty.conf")
        XCTAssertEqual(support.read("Muxy")?.settings, MuxyMigration.Settings())
    }

    func testSettingsFromTheOlderShape() throws {
        let support = Support()
        defer { support.remove() }
        try support.write("[]", "Muxy/projects.json")
        try support.write(json: ["muxy.app.confirmQuit": false, "muxy.notifications.sound": "Glass", "muxy.other": 1], "Muxy/settings.json")
        try support.write("""
        # a comment
        theme = dark
        font-family = "Iosevka Term"
        font-family = Menlo
        font-size = 15
        """, "Muxy/ghostty.conf")
        let settings = try XCTUnwrap(support.read("Muxy")).settings
        XCTAssertEqual(settings, MuxyMigration.Settings(fontFamily: "Iosevka Term", fontSize: 15, confirmQuit: false, notifySound: "Glass"))
        XCTAssertEqual(settings.count, 4)

        for sound in ["None", "Default", "Trumpet"] {
            try support.write(json: ["muxy.notifications.sound": sound, "muxy.app.confirmQuit": "yes"], "Muxy/settings.json")
            XCTAssertNil(support.read("Muxy")?.settings.notifySound, sound)
            XCTAssertNil(support.read("Muxy")?.settings.confirmQuit, "not a bool")
        }
    }

    func testFontSizesOmuxCannotShowAreLeftOut() throws {
        let support = Support()
        defer { support.remove() }
        try support.write("[]", "Muxy/projects.json")
        for (conf, size) in [("font-size = 40", nil), ("font-size = 4", nil), ("font-size = big", nil), ("font-size = '12.5'", 12.5), ("font-size=9", 9.0)] {
            try support.write(conf, "Muxy/ghostty.conf")
            XCTAssertEqual(support.read("Muxy")?.settings.fontSize, size, conf)
        }
        try support.write("font-family = \"\"\nfont-size = 30", "Muxy/ghostty.conf")
        XCTAssertEqual(support.read("Muxy")?.settings, MuxyMigration.Settings(), "an empty family and a size out of range are nothing")
    }

    func testSettingsFromTheNewerShape() throws {
        let support = Support()
        defer { support.remove() }
        try support.write(json: ["version": 3, "projects": []], "Muxy 2/desktop-state.json")
        try support.write("font-family = Menlo\nfont-size = 13\n", "Muxy 2/ghostty.conf")
        try support.write("""
        [appearance]
        url = "system.browser"

        [openers.extra]
        url = "system.browser"

        [ openers ]
        # the browser links open in
        other = 1
        url = "system.browser" # trailing comment

        [panes]
        """, "Muxy 2/settings.toml")
        XCTAssertEqual(support.read("Muxy 2")?.settings, MuxyMigration.Settings(fontFamily: "Menlo", fontSize: 13, openLinksIn: "system"))

        for toml in ["[openers]\nurl = \"omux.browser\"", "[appearance]\nurl = \"system.browser\"", "[openers.extra]\nurl = \"system.browser\"",
                     "[openers]\nurl = system.browser", "url = \"system.browser\""] {
            try support.write(toml, "Muxy 2/settings.toml")
            XCTAssertNil(support.read("Muxy 2")?.settings.openLinksIn, toml)
        }
    }

    func testThePlanSkipsWhatOmuxHasAndWhatIsGone() {
        func project(_ directory: String) -> MuxyMigration.Project { MuxyMigration.Project(name: (directory as NSString).lastPathComponent, directory: directory) }
        var remote = TabGroup(name: "api", directory: "/Users/someone/code/api")
        remote.host = "devbox"
        let existing = [TabGroup(name: "app", directory: "/Users/someone/code/app/"), TabGroup(name: "scratch"), remote]
        let projects = [project("/Users/someone/code/app"), project("/Users/someone/code/api"), project("/Users/someone/code/web"),
                        project("/Users/someone/code/./web"), project("/Users/someone/gone"), project("/Users/someone/gone"), project("")]
        let plan = MuxyMigration.plan(projects, existing: existing) { $0 != "/Users/someone/gone" }
        XCTAssertEqual(plan.add.map(\.directory), ["/Users/someone/code/api", "/Users/someone/code/web"],
                       "the same path on another machine is another folder")
        XCTAssertEqual(plan.alreadyThere, 3, "the app in omux, the second web, the second gone")
        XCTAssertEqual(plan.missingFolder, 1)

        // What was added is there the next time.
        let again = MuxyMigration.plan(projects, existing: existing + MuxyMigration.groups(for: plan.add) { _ in nil }) { $0 != "/Users/someone/gone" }
        XCTAssertEqual(again.add, [])
        XCTAssertEqual(again.alreadyThere, 5)
    }

    /// "~/app", "/Users/me/app/" and "/Users/me/app" are one folder, as everywhere else in omux.
    func testAFolderWrittenAnotherWayIsStillTheSameFolder() {
        let home = NSHomeDirectory()
        let pairs = [("~/code/app", home + "/code/app", true), ("/tmp/app/", "/tmp/app", true), ("/tmp/./app", "/tmp/app", true),
                     ("/tmp/app", "/tmp/App", false), ("/tmp/a", "/tmp/b", false)]
        for (a, b, same) in pairs {
            let plan = MuxyMigration.plan([MuxyMigration.Project(name: "x", directory: b)], existing: [TabGroup(name: "x", directory: a)]) { _ in true }
            XCTAssertEqual(plan.alreadyThere == 1, same, "\(a) and \(b)")
        }
    }

    func testEachProjectBecomesAGroupWithOneSession() {
        let when = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var pinned = MuxyMigration.Project(name: "App", directory: "/Users/someone/code/app", pinned: true, lastActive: when, useWorktrees: true)
        pinned.logo = Data([1, 2, 3])
        let plain = MuxyMigration.Project(name: "Web", directory: "/tmp/web", logo: Data([9]))
        var saved: [Data] = []
        let groups = MuxyMigration.groups(for: [pinned, plain]) { data in
            saved.append(data)
            return data == Data([1, 2, 3]) ? "app.png" : nil
        }
        XCTAssertEqual(saved, [Data([1, 2, 3]), Data([9])])
        XCTAssertEqual(groups.map(\.name), ["App", "Web"])
        XCTAssertEqual(groups.map(\.directory), ["/Users/someone/code/app", "/tmp/web"])
        XCTAssertEqual(groups.map(\.icon), ["app.png", nil], "a picture that couldn't be kept leaves the initials")
        XCTAssertEqual(groups.map(\.pinned), [true, false])
        XCTAssertEqual(groups.map(\.useWorktrees), [true, false])
        XCTAssertEqual(groups.map(\.lastActive), [when, nil])
        XCTAssertEqual(groups.map { $0.tabs.map(\.name) }, [["Session 1"], ["Session 1"]])
        XCTAssertEqual(groups[0].command, TabGroup(name: "x").command)
        XCTAssertEqual(groups[0].provider, TabGroup(name: "x").provider)
        XCTAssertNil(groups[0].host)
        XCTAssertTrue(MuxyMigration.groups(for: [MuxyMigration.Project(name: "Bare", directory: "/tmp/bare")]) { _ in
            XCTFail("no logo, nothing to save"); return nil
        }.allSatisfy { $0.icon == nil })
    }

    func testApplyingWritesOnlyTheSettingsThatAreSet() throws {
        let suite = "omux-muxy-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Glass", forKey: Prefs.notifySound)

        XCTAssertEqual(MuxyMigration.apply(MuxyMigration.Settings(), to: defaults), 0)
        XCTAssertEqual(defaults.string(forKey: Prefs.notifySound), "Glass", "nothing set, nothing touched")

        let settings = MuxyMigration.Settings(fontFamily: "Menlo", fontSize: 14, confirmQuit: false, openLinksIn: "system")
        XCTAssertEqual(MuxyMigration.apply(settings, to: defaults), 4)
        XCTAssertEqual(defaults.string(forKey: Prefs.fontFamily), "Menlo")
        XCTAssertEqual(defaults.double(forKey: Prefs.fontSize), 14)
        XCTAssertEqual(defaults.object(forKey: Prefs.confirmQuit) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: Prefs.openLinksIn), "system")
        XCTAssertEqual(defaults.string(forKey: Prefs.notifySound), "Glass")
    }
}
