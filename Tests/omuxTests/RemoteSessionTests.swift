import XCTest
@testable import omux
@testable import OmuxCore

/// Projects on another machine: what the session's terminal runs, and how a project says
/// where it lives.
final class RemoteSessionTests: XCTestCase {
    private let tab = UUID(uuidString: "0B1C2D3E-0000-4000-8000-0000000000AA")!

    func testTheFarEndIsAskedForTheTabsOwnSession() {
        let command = RemoteHost.remoteCommand(tab: tab, name: "fix it's bug", directory: "~/code/my app", run: "claude --session-id x")
        XCTAssertTrue(command.hasPrefix("exec ~/.omux/bin/omux-host session 0b1c2d3e-0000-4000-8000-0000000000aa "), command)
        // Each value is one word to the far shell, whatever is in it.
        XCTAssertTrue(command.contains(#"--name 'fix it'\''s bug'"#), command)
        XCTAssertTrue(command.contains("--dir '~/code/my app'"), command)
        XCTAssertTrue(command.contains("--run 'claude --session-id x'"), command)
        XCTAssertFalse(RemoteHost.remoteCommand(tab: tab, name: "shell", directory: nil, run: nil).contains("--dir"))
    }

    func testTheScriptSetsUpAttachesAndComesBack() throws {
        let script = RemoteHost.script(host: "me@dev box", tab: tab, name: "s", directory: "/srv/app", run: nil)
        XCTAssertTrue(script.contains("H='me@dev box'"))
        XCTAssertTrue(script.contains("sha256sum ~/.omux/bin/omux-host"), "checks which host program is there before attaching")
        XCTAssertTrue(script.contains("[ $code -ne 255 ] && exit $code"), "only a lost connection is retried")
        // It is a shell script: the shell must take it.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", "-c", script]
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        if let path = ProcessInfo.processInfo.environment["OMUX_DUMP_SCRIPT"] { try script.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    func testAProjectRemembersItsMachine() throws {
        var group = TabGroup(name: "api", directory: "~/api")
        XCTAssertFalse(group.isRemote)
        group.host = "devbox"
        let back = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(back.host, "devbox")
        XCTAssertTrue(back.isRemote)
        // A workspace saved before there were remote projects.
        let old = try JSONDecoder().decode(TabGroup.self, from: Data(#"{"name":"old","tabs":[]}"#.utf8))
        XCTAssertNil(old.host)
        XCTAssertFalse(old.isRemote)
    }

    func testEachRemoteSessionHasItsOwnCopyFolder() {
        let a = RemoteHost.mirrorFolder(host: "me@dev/box", tab: tab)
        XCTAssertEqual(a.lastPathComponent, "0b1c2d3e-0000-4000-8000-0000000000aa")
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "me_dev_box", "a host is one folder, whatever it is called")
    }
}
