import XCTest
@testable import omux
@testable import OmuxCore

final class ClaudeModelsTests: XCTestCase {
    func testModelIDsAreReadOutOfBytesAndTheNewestOfEachFamilyIsOffered() {
        let bytes = Data("""
        x claude-fable-5-2 y claude-fable-5-1\0claude-fable-5 "claude-opus-4-5-20251101" claude-opus-5-5,claude-opus-5
        claude-sonnet-5 claude-sonnet-4-6 claude-haiku-5-5 claude-haiku-4-5-20251001 claude-mythos-5-2 claude-3-5-sonnet-20241022
        claudette claude-opus-x claude-
        """.utf8)
        let ids = ClaudeModels.ids(in: bytes)
        XCTAssertEqual(ids, ["claude-fable-5-2", "claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5",
                             "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5-5", "claude-mythos-5-2"])
        XCTAssertEqual(ClaudeModels.newest(in: ids), ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5-5"])
        // A family the program doesn't know is left out, not shown as a blank.
        XCTAssertEqual(ClaudeModels.newest(in: ["claude-opus-4-8", "claude-opus-4-10"]), ["claude-opus-4-10"])
    }

    /// The installed Claude Code, when there is one: its program names a Fable model.
    func testTheInstalledClaudeCodeListsItsModels() throws {
        guard let program = ClaudeModels.program(), let data = try? Data(contentsOf: program, options: .mappedIfSafe) else {
            throw XCTSkip("no claude on the PATH")
        }
        let newest = ClaudeModels.newest(in: ClaudeModels.ids(in: data))
        XCTAssertEqual(newest.count, 4, "\(program.path): \(newest)")
        XCTAssertTrue(newest[0].hasPrefix("claude-fable-"))
    }
}
