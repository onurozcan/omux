import XCTest
@testable import omux

final class FilePreviewTests: XCTestCase {
    /// Whether the preview built for `url` holds `marker`, i.e. shows the file as text.
    @MainActor
    private func shows(_ marker: String, for url: URL) -> Bool {
        var out = ""
        dump(FilePreview(url: url).body, to: &out, maxDepth: 60)
        return out.contains(marker)
    }

    /// A symlink is a few bytes itself; read through it, a big log froze the window for seconds.
    @MainActor
    func testTextLimitAppliesToWhatALinkPointsAt() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let small = dir.appendingPathComponent("small.log"), big = dir.appendingPathComponent("big.log")
        try "small-marker\n".write(to: small, atomically: true, encoding: .utf8)
        try ("big-marker\n" + String(repeating: "x", count: 1_100_000)).write(to: big, atomically: true, encoding: .utf8)
        let smallLink = dir.appendingPathComponent("small-link.log"), bigLink = dir.appendingPathComponent("big-link.log")
        try fm.createSymbolicLink(at: smallLink, withDestinationURL: small)
        try fm.createSymbolicLink(at: bigLink, withDestinationURL: big)

        XCTAssertTrue(shows("small-marker", for: small))
        XCTAssertTrue(shows("small-marker", for: smallLink))
        XCTAssertFalse(shows("big-marker", for: big))
        XCTAssertFalse(shows("big-marker", for: bigLink))
    }

    /// Markdown had no limit: a 2 MB changelog froze the window for 45 s.
    @MainActor
    func testMarkdownHasTheTextLimit() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let small = dir.appendingPathComponent("README.md"), big = dir.appendingPathComponent("CHANGELOG.md")
        try "# small-marker\n".write(to: small, atomically: true, encoding: .utf8)
        try ("# big-marker\n" + String(repeating: "- item\n", count: 160_000)).write(to: big, atomically: true, encoding: .utf8)

        XCTAssertTrue(shows("small-marker", for: small))
        XCTAssertFalse(shows("big-marker", for: big))
    }
}
