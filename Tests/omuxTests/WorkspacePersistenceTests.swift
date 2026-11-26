import XCTest
@testable import omux

/// A workspace omux can't read in full must be kept before anything replaces it: after a load
/// that finds nothing, the saves that follow overwrite workspace.json and then its backup.
final class WorkspacePersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omux-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Both files unreadable used to load as no workspace. Store then saved its "Default" project
    /// over workspace.json, which moved the unreadable file into the backup, and the next save
    /// put "Default" over the backup too.
    func testAWorkspaceThatCantBeReadIsKeptBeforeSavesReplaceIt() throws {
        let current = #"{"groups": [{"name": "app", "tabs": [{"name": "#
        let backup = #"{"groups": "not a list"}"#
        try write(current, to: Persistence.workspaceURL(in: dir))
        try write(backup, to: Persistence.backupURL(in: dir))

        let loaded = Persistence.loadWorkspace(in: dir)
        XCTAssertNil(loaded.workspace)
        XCTAssertEqual(loaded.kept.count, 2)

        // What Store does next: save the Default project, then save again on the first change.
        Persistence.save(Workspace(groups: [TabGroup(name: "Default", tabs: [TabItem(name: "Session 1")])]), in: dir)
        Persistence.save(Workspace(groups: [TabGroup(name: "Default", tabs: [TabItem(name: "Session 2")])]), in: dir)
        XCTAssertEqual(Set(try loaded.kept.map(text(of:))), [current, backup])
    }

    /// One session or project that can't be read is left out and the rest open. The file is
    /// kept too, since the next save writes the workspace without what was left out.
    func testOneUnreadableEntryDoesNotTakeTheWorkspaceWithIt() throws {
        let file = """
        {"groups": [
          {"name": "app", "tabs": [{"name": "one"}, null, {"name": "bad id", "id": 42}, {"name": "two"}]},
          {"name": "broken", "tabs": "not a list"},
          {"name": "api", "tabs": [{"name": "server"}]}
        ]}
        """
        try write(file, to: Persistence.workspaceURL(in: dir))

        let loaded = Persistence.loadWorkspace(in: dir)
        let groups = try XCTUnwrap(loaded.workspace?.groups)
        XCTAssertEqual(groups.map(\.name), ["app", "api"])
        XCTAssertEqual(groups[0].tabs.map(\.name), ["one", "two"])
        XCTAssertEqual(groups[1].tabs.map(\.name), ["server"])
        XCTAssertEqual(try loaded.kept.map(text(of:)), [file])
    }

    /// An unreadable workspace.json falls back to the backup, as before, and is kept.
    func testAnUnreadableWorkspaceOpensTheBackupAndIsKept() throws {
        Persistence.save(Workspace(groups: [TabGroup(name: "app")]), in: dir)
        Persistence.save(Workspace(groups: [TabGroup(name: "app"), TabGroup(name: "api")]), in: dir)
        try write("{", to: Persistence.workspaceURL(in: dir))

        let loaded = Persistence.loadWorkspace(in: dir)
        XCTAssertEqual(loaded.workspace?.groups.map(\.name), ["app"])
        XCTAssertEqual(try loaded.kept.map(text(of:)), ["{"])
        XCTAssertTrue(loaded.kept.allSatisfy { $0.lastPathComponent.hasPrefix("workspace-unreadable-") })
    }

    /// Opened again before anything was saved over it, the same file is kept once, not once per launch.
    func testAFileStillUnreadableIsKeptOnce() throws {
        try write(#"{"groups": [{"name": "app", "tabs": [{"id": 1}]}]}"#, to: Persistence.workspaceURL(in: dir))

        let first = Persistence.loadWorkspace(in: dir)
        let second = Persistence.loadWorkspace(in: dir)
        XCTAssertEqual(first.kept.count, 1)
        XCTAssertEqual(second.kept, first.kept)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["workspace.json", first.kept[0].lastPathComponent].sorted())
    }

    /// A workspace read in full opens as it was saved, with nothing copied beside it.
    func testAReadableWorkspaceIsNotCopied() throws {
        var group = TabGroup(name: "app", tabs: [TabItem(name: "one"), TabItem(name: "two")])
        group.pinned = true
        Persistence.save(Workspace(groups: [group]), in: dir)

        let loaded = Persistence.loadWorkspace(in: dir)
        XCTAssertEqual(loaded.workspace?.groups, [group])
        XCTAssertEqual(loaded.kept, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["workspace.json"])
    }
}
