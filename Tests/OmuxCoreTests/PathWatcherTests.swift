import XCTest
@testable import OmuxCore

/// File events are what the transcript and subagent readers follow; this runs on Linux too,
/// where the watcher is inotify instead of a vnode source.
final class PathWatcherTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omux-watch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func until(_ deadline: Duration = .seconds(3), _ holds: () -> Bool) async throws {
        let end = ContinuousClock.now + deadline
        while !holds(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    func testAFileWatcherWakesOnAppendsAndAFolderWatcherOnNewEntries() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)
        var fileEvents = 0, folderEvents = 0
        let fileWatcher = PathWatcher(path: file.path) { fileEvents += 1 }
        let folderWatcher = PathWatcher(path: dir.path, directory: true) { folderEvents += 1 }
        XCTAssertNotNil(fileWatcher); XCTAssertNotNil(folderWatcher)
        XCTAssertNil(PathWatcher(path: dir.appendingPathComponent("missing").path) {})

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("hello\n".utf8)); try handle.close()
        try await until { fileEvents > 0 }
        XCTAssertGreaterThan(fileEvents, 0)
        XCTAssertEqual(folderEvents, 0, "writing inside a file is not a change to the folder's entries")

        try "".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await until { folderEvents > 0 }
        XCTAssertGreaterThan(folderEvents, 0)
        _ = fileWatcher; _ = folderWatcher
    }
}
