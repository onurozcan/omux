import XCTest
@testable import omux

final class SendTests: XCTestCase {
    /// A Return the agent took as a line break leaves the prompt in its input box: the last
    /// screen line starting with the prompt mark. A submitted prompt leaves the box empty, and
    /// the prompt echoed above it (Claude Code's "> ") doesn't count.
    func testPromptStillInTheInputBoxIsRecognised() {
        let head = Store.inputHead(of: "whats graph engineering\nsecond line")
        XCTAssertEqual(head, "whats graph engineering")
        XCTAssertTrue(Store.inputHolds(head, in: ["──────", "❯ whats graph engineering", "──────", "  ~/omux  main"]))
        XCTAssertTrue(Store.inputHolds(head, in: ["› whats graph engineering", "  ? for shortcuts"]))
        XCTAssertFalse(Store.inputHolds(head, in: ["> whats graph engineering", "──────", "❯\u{a0}", "──────"]))
        XCTAssertFalse(Store.inputHolds(head, in: ["Trust this folder?", "  1. Yes"]))
        XCTAssertFalse(Store.inputHolds("ok", in: ["❯ ok"]))
    }

    /// Codex updates itself on launch and quits asking for a restart; omux reads that off the
    /// screen. The input box of either agent is a line starting with its prompt mark.
    func testScreenTellsASelfUpdateFromAnInputBox() {
        XCTAssertTrue(Store.asksForRestart(["changed 2 packages in 8s", "", "🎉 Update ran successfully! Please restart Codex.", "onur@mac ~ %"]))
        XCTAssertFalse(Store.asksForRestart(["› ", "  ? for shortcuts"]))
        XCTAssertTrue(Store.showsComposer(["› ", "  ? for shortcuts"]))
        XCTAssertTrue(Store.showsComposer(["──────", "❯ ", "──────"]))
        XCTAssertFalse(Store.showsComposer(["Updating Codex via `npm install -g @openai/codex`", "onur@mac ~ %"]))
    }

    /// The app-server runs under a shell that follows omux out, so a crash leaves no Codex
    /// behind holding the conversation's writer lock. When one does, the error says what to do.
    func testAppServerFollowsOmuxOut() {
        let command = CodexConnection.watchedCommand("codex app-server --listen ws://127.0.0.1:1", parent: 4242)
        XCTAssertTrue(command.hasPrefix("codex app-server --listen ws://127.0.0.1:1 & child=$!"))
        XCTAssertTrue(command.contains("kill -0 4242"))
        XCTAssertTrue(command.contains("trap 'kill $child"))
        XCTAssertTrue(Store.codexStartFailure(CodexError.server("thread 01a1 already has an active writer")).contains("Another Codex"))
        XCTAssertEqual(Store.codexStartFailure(CodexError.server("no such thread")), CodexError.server("no such thread").localizedDescription)
    }

    func testClaudeDialogsOnTheScreenAreRecognised() {
        XCTAssertTrue(Store.showsDialog(["Switch model?", "", "The conversation is cached…", "  Yes, switch", "  No, go back"]))
        XCTAssertTrue(Store.showsDialog(["Do you trust this folder?", "  1. Yes"]))
        XCTAssertFalse(Store.showsDialog(["● pong7", "", "❯ "]))
    }

    /// The agents animate a spinner in front of the title; the title is what comes after it.
    func testSpinnersAreNotPartOfTheTitle() {
        XCTAssertEqual(Store.cleanTitle("⠙ LocaleSwitcher review | acme-web"), "LocaleSwitcher review | acme-web")
        XCTAssertEqual(Store.cleanTitle("✳ Settings i18n"), "Settings i18n")
        XCTAssertEqual(Store.cleanTitle("Settings i18n"), "Settings i18n")
        XCTAssertEqual(Store.cleanTitle("⋮ LocaleSwitcher review"), "LocaleSwitcher review")
    }

    func testShellPathKeepsOrderAndDropsDuplicates() {
        XCTAssertEqual(ShellPath.joined(["/a", "", "/b", "/a", "/c"]), "/a:/b:/c")
        XCTAssertTrue(ShellPath.current.split(separator: ":").contains("/usr/bin"))
    }
}
