import XCTest
@testable import omux

/// Where a file from another machine is copied to here.
final class RemoteFilesTests: XCTestCase {
    private let files = RemoteHost.mirrorRoot.appendingPathComponent("devbox/files", isDirectory: true).standardizedFileURL.path

    func testAnOrdinaryPathMapsUnderTheHostsFiles() throws {
        let local = try XCTUnwrap(RemoteFiles.localURL(host: "devbox", path: "/home/u/p/file.txt"))
        XCTAssertEqual(local.standardizedFileURL.path, files + "/home/u/p/file.txt")
        let home = try XCTUnwrap(RemoteFiles.localURL(host: "devbox", path: "~/p/file.txt"))
        XCTAssertEqual(home.standardizedFileURL.path, files + "/~/p/file.txt")
    }

    func testDotDotNeverLeavesTheHostsFiles() throws {
        // ".." at "/" stays at "/", as the shell there does: the same file, copied inside.
        let rooted = try XCTUnwrap(RemoteFiles.localURL(host: "devbox", path: "/a/../../../../../../tmp/x"))
        XCTAssertEqual(rooted.standardizedFileURL.path, files + "/tmp/x")
        let home = try XCTUnwrap(RemoteFiles.localURL(host: "devbox", path: "~/p/../q/x"))
        XCTAssertEqual(home.standardizedFileURL.path, files + "/~/q/x")
        // Above the home folder, or above wherever a relative path starts, is refused, not remapped.
        for path in ["~/../../tmp/x", "../../tmp/x", "~/..", "a/../../x"] {
            XCTAssertNil(RemoteFiles.normalized(path), path)
            XCTAssertNil(RemoteFiles.localURL(host: "devbox", path: path), path)
        }
        XCTAssertEqual(RemoteFiles.normalized("/a/../../../../../../tmp/x"), "/tmp/x")
        XCTAssertEqual(RemoteFiles.normalized("/./a/./../b//x"), "/b/x")
        XCTAssertEqual(RemoteFiles.normalized("~/a/../b"), "~/b")
        XCTAssertEqual(RemoteFiles.normalized("~"), "~")
    }

    func testAHostNamedToClimbOutIsRefused() {
        XCTAssertNil(RemoteFiles.localURL(host: "..", path: "/x"))
    }
}
