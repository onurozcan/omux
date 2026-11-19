import XCTest
@testable import omux
@testable import OmuxCore

/// Timing harnesses, skipped unless pointed at data: OMUX_PROFILE=<transcript.jsonl> swift test
/// -c release -Xswiftc -enable-testing --filter ProfileTests
final class ProfileTests: XCTestCase {
    /// How long a long conversation takes to load: the 4 MB tail is parsed off the main thread,
    /// then applied and encoded on it. 441 MB and 110 MB transcripts took 60 and 125 ms in all.
    @MainActor
    func testLoadOfALargeTranscript() async throws {
        guard let path = ProcessInfo.processInfo.environment["OMUX_PROFILE"] else { throw XCTSkip("set OMUX_PROFILE to a transcript path") }
        let url = URL(fileURLWithPath: path)
        let start = ContinuousClock.now
        let model = SessionTranscript(tab: TabItem(name: "profile"), provider: .claude, claudeFile: { url }, codexThread: { nil })
        while !model.loaded { try await Task.sleep(for: .milliseconds(2)) }
        print("PROFILE total until loaded=\(ContinuousClock.now - start)")
    }
}
