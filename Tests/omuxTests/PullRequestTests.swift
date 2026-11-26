import XCTest
@testable import omux

final class PullRequestTests: XCTestCase {
    private func parse(state: String = "OPEN", mergeable: String?, base: String? = nil) -> PullRequest? {
        let fields = [mergeable.map { #","mergeable":"\#($0)""# }, base.map { #","baseRefName":"\#($0)""# }]
            .compactMap { $0 }.joined()
        return PullRequestMonitor.parse(#"{"number":7,"title":"t","url":"https://github.com/o/r/pull/7","state":"\#(state)","isDraft":false\#(fields)}"#)
    }

    func testMergeableIsRead() {
        XCTAssertEqual(parse(mergeable: "CONFLICTING")?.conflicts, true)
        XCTAssertEqual(parse(mergeable: "MERGEABLE")?.conflicts, false)
        XCTAssertNotNil(parse(mergeable: "UNKNOWN"))
        XCTAssertNil(parse(mergeable: "UNKNOWN")?.conflicts)
        XCTAssertNotNil(parse(mergeable: nil))
        XCTAssertNil(parse(mergeable: nil)?.conflicts)
    }

    func testOnlyOpenPullRequestsConflict() {
        XCTAssertNil(parse(state: "MERGED", mergeable: "CONFLICTING")?.conflicts)
        XCTAssertNil(parse(state: "CLOSED", mergeable: "CONFLICTING")?.conflicts)
    }

    func testUnknownKeepsTheLastKnownAnswer() throws {
        let conflicting = try XCTUnwrap(parse(mergeable: "CONFLICTING"))
        let mergeable = try XCTUnwrap(parse(mergeable: "MERGEABLE"))
        let unknown = try XCTUnwrap(parse(mergeable: "UNKNOWN"))
        XCTAssertEqual(unknown.keepingConflicts(of: conflicting).conflicts, true)
        XCTAssertEqual(unknown.keepingConflicts(of: mergeable).conflicts, false)
        XCTAssertNil(unknown.keepingConflicts(of: nil).conflicts)
        XCTAssertEqual(mergeable.keepingConflicts(of: conflicting).conflicts, false)
    }

    func testUnknownDoesNotKeepAnotherPullRequestsAnswer() throws {
        let conflicting = try XCTUnwrap(parse(mergeable: "CONFLICTING", base: "main"))
        let retargeted = try XCTUnwrap(parse(mergeable: "UNKNOWN", base: "develop"))
        XCTAssertNil(retargeted.keepingConflicts(of: conflicting).conflicts)
        let other = try XCTUnwrap(PullRequestMonitor.parse(
            #"{"number":8,"title":"t","url":"https://github.com/o/r/pull/8","state":"OPEN","isDraft":false,"mergeable":"UNKNOWN","baseRefName":"main"}"#))
        XCTAssertNil(other.keepingConflicts(of: conflicting).conflicts)
    }

    func testNewConflictsNeedAttention() throws {
        let conflicting = try XCTUnwrap(parse(mergeable: "CONFLICTING"))
        let mergeable = try XCTUnwrap(parse(mergeable: "MERGEABLE"))
        XCTAssertTrue(conflicting.needsAttention(since: mergeable))
        XCTAssertFalse(conflicting.needsAttention(since: conflicting))
        XCTAssertFalse(mergeable.needsAttention(since: conflicting))
        XCTAssertEqual(conflicting.summary, "Conflicts")
    }

    func testConflictsPrompt() throws {
        XCTAssertEqual(try XCTUnwrap(parse(mergeable: "CONFLICTING")).conflictsPrompt(base: "main"),
                       "Pull request #7 conflicts with main. Fetch origin, merge origin/main into this branch, "
                           + "resolve the conflicts, run the tests, and commit.")
    }

    func testBaseIsRead() {
        XCTAssertEqual(parse(mergeable: nil, base: "release/1.2")?.base, "release/1.2")
        XCTAssertNil(parse(mergeable: nil)?.base)
        // Anything a shell would read as more than a branch name is dropped.
        XCTAssertNil(parse(mergeable: nil, base: "main;rm -rf ~")?.base)
        XCTAssertNil(parse(mergeable: nil, base: "$(id)")?.base)
    }
}
