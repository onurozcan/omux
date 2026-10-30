import XCTest
@testable import omux

final class SessionProviderTests: XCTestCase {
    func testLegacyWorkspacePreservesClaudeIdentityAndCommand() throws {
        let id = UUID()
        let data = Data("""
        {"command":"claude --model opus","tabs":[{"claudeSessionID":"\(id)","name":"Existing"}]}
        """.utf8)
        let group = try JSONDecoder().decode(TabGroup.self, from: data)
        XCTAssertEqual(group.provider, .claude)
        XCTAssertEqual(group.tabs[0].claudeSessionID, id)
        XCTAssertEqual(group.tabs[0].resolvedProvider(in: group), .claude)
        XCTAssertEqual(group.command, "claude --model opus")
    }

    func testValuesFromANewerVersionDoNotDropTheWorkspace() throws {
        let data = Data("""
        {"groups":[{"name":"Work","command":"codex","provider":"future","tabs":[{"name":"A","provider":"future","color":"future","command":"claude"}]}]}
        """.utf8)
        let group = try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).groups.first)
        XCTAssertEqual(group.provider, .codex)
        XCTAssertNil(group.tabs[0].provider)
        XCTAssertEqual(group.tabs[0].resolvedProvider(in: group), .claude)
        XCTAssertEqual(group.tabs[0].color, TabColor.none)
    }

    func testShellOverrideDoesNotInheritProjectAgent() {
        let group = TabGroup(name: "Project")
        let tab = TabItem(name: "Shell", command: "")
        XCTAssertEqual(tab.resolvedProvider(in: group), .shell)
    }

    func testCodexIdentitySurvivesRoundTrip() throws {
        var group = TabGroup(name: "Project")
        group.provider = .codex
        group.command = "codex"
        var tab = TabItem(name: "Codex")
        tab.codexThreadID = "thread-assigned-by-server"
        group.tabs = [tab]
        let restored = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(restored.tabs[0].resolvedProvider(in: restored), .codex)
        XCTAssertEqual(restored.tabs[0].codexThreadID, tab.codexThreadID)
    }

    func testCustomCommandsRemainCustom() {
        for command in ["env codex", "codex exec task", "npm run dev", "/path/to/wrapper"] {
            XCTAssertEqual(SessionProvider.infer(command: command), .custom)
        }
    }

    func testClaudeStartsANewPinnedConversationInsteadOfContinuingAnotherTab() {
        let id = UUID()
        XCTAssertEqual(SessionProvider.claudeCommand("claude --model opus", sessionID: id, conversationExists: false),
                       "claude --session-id \(id.uuidString.lowercased()) --model opus")
        XCTAssertEqual(SessionProvider.claudeCommand("claude", sessionID: id, conversationExists: true),
                       "claude --resume \(id.uuidString.lowercased())")
    }

    func testExplicitClaudeSessionFlagsArePreserved() {
        for raw in ["claude --resume abc", "claude --resume=abc", "claude --session-id=abc", "claude --continue"] {
            XCTAssertEqual(SessionProvider.claudeCommand(raw, sessionID: UUID(), conversationExists: false), raw)
        }
    }

    func testStandardCursorCommandsPickTheCursorProvider() {
        XCTAssertEqual(SessionProvider.infer(command: "cursor-agent"), .cursor)
        XCTAssertEqual(SessionProvider.infer(command: "cursor-agent --model gpt-5"), .cursor)
    }

    func testCursorResumesItsOwnChatOnceItHasOne() {
        XCTAssertEqual(SessionProvider.cursorCommand("cursor-agent", chatID: "chat-1"),
                       "cursor-agent --resume chat-1")
        XCTAssertEqual(SessionProvider.cursorCommand("cursor-agent --model gpt-5", chatID: "chat-1"),
                       "cursor-agent --resume chat-1 --model gpt-5")
        // Nothing to resume yet: the first run starts the chat Cursor will give us an id for.
        XCTAssertEqual(SessionProvider.cursorCommand("cursor-agent", chatID: nil), "cursor-agent")
    }

    func testExplicitCursorChatChoicesArePreserved() {
        for raw in ["cursor-agent --resume abc", "cursor-agent --resume=abc", "cursor-agent --continue", "cursor-agent ls"] {
            XCTAssertEqual(SessionProvider.cursorCommand(raw, chatID: "chat-1"), raw)
        }
    }

    func testCursorIdentitySurvivesRoundTrip() throws {
        var group = TabGroup(name: "Project")
        group.provider = .cursor
        group.command = "cursor-agent"
        var tab = TabItem(name: "Cursor")
        tab.cursorChatID = "chat-assigned-by-cursor"
        group.tabs = [tab]
        let restored = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(restored.tabs[0].resolvedProvider(in: restored), .cursor)
        XCTAssertEqual(restored.tabs[0].cursorChatID, tab.cursorChatID)
    }
}
