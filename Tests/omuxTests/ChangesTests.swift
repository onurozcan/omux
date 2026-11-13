import XCTest
@testable import omux
@testable import OmuxCore

final class ChangesTests: XCTestCase {
    private func makeRepo() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        try "one\n".write(toFile: dir + "/sub/file.txt", atomically: true, encoding: .utf8)
        git(["init", "-q", "-b", "main"], in: dir)
        git(["add", "."], in: dir)
        commit("first", in: dir)
        return dir
    }

    @discardableResult
    private func git(_ args: [String], in dir: String) -> Git.Result {
        let result = Git.run(args, in: dir)
        XCTAssertTrue(result.ok, result.message)
        return result
    }

    private func commit(_ message: String, in dir: String) {
        git(["-c", "user.name=omux", "-c", "user.email=omux@example.com", "commit", "-qam", message], in: dir)
    }

    func testTotalsSkipBinaryFiles() {
        let files = [ChangedFile(path: "a", added: 3, removed: 1, status: .modified),
                     ChangedFile(path: "b", added: nil, removed: nil, status: .modified),
                     ChangedFile(path: "c", added: 2, removed: 0, status: .untracked)]
        XCTAssertEqual(files.totals, DiffStat(added: 5, removed: 1))
        XCTAssertTrue([ChangedFile]().totals.isEmpty)
    }

    func testGitDirectoryOfLinkedWorktreeIsOutsideIt() throws {
        let repo = try makeRepo()
        let linked = repo + "-linked"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: linked) }
        git(["worktree", "add", "-q", "-b", "other", linked], in: repo)
        // git reports the real path, without the /private that temporary folders resolve to.
        let root = try XCTUnwrap(Git.topLevel(repo))
        XCTAssertEqual(Git.gitDirectory(repo), root + "/.git")
        XCTAssertEqual(Git.gitDirectory(repo + "/sub"), root + "/.git")
        XCTAssertEqual(Git.gitDirectory(linked), root + "/.git/worktrees/" + (linked as NSString).lastPathComponent)
        XCTAssertNil(Git.gitDirectory(NSTemporaryDirectory()))
    }

    /// A commit in a session in a subfolder only touches the repository's .git, above the
    /// session's folder, so watching that folder alone leaves the commit on the list.
    @MainActor
    func testCommitOutsideTheFolderRefreshes() async throws {
        let repo = try makeRepo()
        let dir = repo + "/sub"
        try "two\n".write(toFile: dir + "/file.txt", atomically: true, encoding: .utf8)
        let changes = Changes()
        changes.track(tabID: UUID(), dir: dir, worktree: nil)
        try await waitUntil { changes.files.count == 1 }
        commit("second", in: repo)
        try await waitUntil { changes.files.isEmpty }
    }

    /// A linked worktree's HEAD and index are under the main repository's .git.
    @MainActor
    func testCommitInLinkedWorktreeRefreshes() async throws {
        let repo = try makeRepo()
        let linked = repo + "-linked"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: linked) }
        git(["worktree", "add", "-q", "-b", "other", linked], in: repo)
        try "two\n".write(toFile: linked + "/sub/file.txt", atomically: true, encoding: .utf8)
        let changes = Changes()
        changes.track(tabID: UUID(), dir: linked, worktree: nil)
        try await waitUntil { changes.files.count == 1 }
        commit("second", in: linked)
        try await waitUntil { changes.files.isEmpty }
    }

    @MainActor
    func testRepositoryCreatedLaterIsFound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let changes = Changes()
        changes.track(tabID: UUID(), dir: dir, worktree: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(changes.isRepo)
        git(["init", "-q"], in: dir)
        changes.refresh()
        try await waitUntil { changes.isRepo }
    }

    func testSubfolderPathsAreFromTheSessionFolder() throws {
        let repo = try makeRepo()
        let dir = repo + "/sub"
        try "one\ntwo\n".write(toFile: dir + "/file.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
        let files = Git.changedFiles(dir: dir, base: "HEAD")
        XCTAssertEqual(files.map(\.path), ["file.txt", "new.txt"])
        let diff = Git.diff(dir: dir, base: "HEAD", file: files[0])
        XCTAssertEqual(diff.filter { $0.kind == .added }.map(\.text), ["two"])
    }

    func testNamesAreNotPathspecPatterns() throws {
        let repo = try makeRepo()
        for name in ["a*", "abc", ":colon"] { try "x\n".write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }
        git(["add", "."], in: repo)
        commit("names", in: repo)
        for name in ["a*", "abc", ":colon"] { try "x\ny\n".write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }
        for file in Git.changedFiles(dir: repo, base: "HEAD") {
            XCTAssertEqual(Git.diff(dir: repo, base: "HEAD", file: file).filter { $0.kind == .added }.map(\.text), ["y"], file.path)
        }
    }

    func testStagedFilesShowBeforeTheFirstCommit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        git(["init", "-q"], in: dir)
        try "hi\n".write(toFile: dir + "/staged.txt", atomically: true, encoding: .utf8)
        git(["add", "staged.txt"], in: dir)
        let files = Git.changedFiles(dir: dir, base: Git.diffBase(dir: dir, worktree: nil))
        XCTAssertEqual(files.map(\.path), ["staged.txt"])
        XCTAssertEqual(files.first?.status, .added)
    }

    func testSymlinkToABigFileCountsAsBig() throws {
        let repo = try makeRepo()
        let big = repo + "-big"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: big) }
        try String(repeating: "line\n", count: 400_000).write(toFile: big, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo + "/link", withDestinationPath: big)
        XCTAssertNil(Git.textLines(atPath: repo + "/link"))
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
