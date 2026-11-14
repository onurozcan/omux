import XCTest
@testable import OmuxCore

/// A folder on another machine as one string, and Git run there.
final class RemotePathTests: XCTestCase {
    func testAFolderElsewhereIsOneString() {
        for (host, path) in [("devbox", "/srv/app"), ("me@10.0.0.5", "~/code/my app"), ("h", "~"), ("user@host.example.com", "/a/b c/d")] {
            let location = RemotePath.make(host: host, path: path)
            XCTAssertTrue(RemotePath.isRemote(location))
            let back = RemotePath.parse(location)
            XCTAssertEqual(back?.host, host, location)
            XCTAssertEqual(back?.path, path, location)
        }
        XCTAssertEqual(RemotePath.parse(RemotePath.make(host: "h", path: ""))?.path, "~", "no folder is the home folder")
        for local in ["/Users/me/code", "~/code", "", "ssh://host/path", "omux-ssh://", "omux-ssh:///nohost"] {
            XCTAssertNil(RemotePath.parse(local), local)
        }
        XCTAssertFalse(RemotePath.isRemote("/Users/me/code"))
    }

    func testEnteringAFolderNeverRunsItsName() throws {
        let script = RemotePath.entering("~/it's $(touch /tmp/pwned) `x`") + "pwd"
        XCTAssertTrue(script.contains(#"D='~/it'\''s $(touch /tmp/pwned) `x`'"#), script)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", "-c", script]
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }

    /// Against a real machine, when one is named: OMUX_LIVE_HOST=devbox swift test --filter RemotePathTests
    func testGitOnALiveMachine() throws {
        guard let host = ProcessInfo.processInfo.environment["OMUX_LIVE_HOST"], !host.isEmpty else { throw XCTSkip("no OMUX_LIVE_HOST") }
        let folder = "/tmp/omux-git-\(UInt32.random(in: 0...999_999))"
        let setup = RemotePath.run("""
        mkdir -p \(folder)/sub && cd \(folder) && git init -q && git config user.email t@t && git config user.name t &&
        printf 'one\\ntwo\\n' > kept.txt && printf 'gone\\n' > removed.txt && git add . && git commit -q -m first &&
        printf 'one\\nTWO\\nthree\\n' > kept.txt && rm removed.txt && printf 'a\\nb\\nc\\n' > 'sub/new file.txt'
        """, on: host)
        try XCTSkipIf(setup.status != 0, "no git there: \(setup.error)")
        defer { _ = RemotePath.run("rm -rf \(folder)", on: host) }
        let location = RemotePath.make(host: host, path: folder)
        XCTAssertEqual(Git.topLevel(location), folder)
        XCTAssertNil(Git.topLevel(RemotePath.make(host: host, path: "/tmp")), "not a checkout")
        let base = Git.diffBase(dir: location, worktree: nil)
        XCTAssertEqual(base, "HEAD")
        let files = Git.changedFiles(dir: location, base: base)
        print("LIVE changed:", files.map { "\($0.path) \($0.status) +\($0.added ?? -1) -\($0.removed ?? -1)" })
        XCTAssertEqual(files.map(\.path), ["kept.txt", "removed.txt", "sub/new file.txt"])
        XCTAssertEqual(files.map(\.status), [.modified, .deleted, .untracked])
        XCTAssertEqual(files.first?.added, 2); XCTAssertEqual(files.first?.removed, 1)
        XCTAssertEqual(files.last?.added, 3)
        let diff = Git.diff(dir: location, base: base, file: files[0])
        XCTAssertTrue(diff.contains { $0.kind == .added && $0.text == "TWO" })
        XCTAssertTrue(diff.contains { $0.kind == .removed && $0.text == "two" })
        let fresh = Git.diff(dir: location, base: base, file: files[2])
        XCTAssertEqual(fresh.filter { $0.kind == .added }.map(\.text), ["a", "b", "c"])
        XCTAssertFalse(Git.login("true", in: location).ok, "nothing is pushed from here for a folder elsewhere")
    }
}
