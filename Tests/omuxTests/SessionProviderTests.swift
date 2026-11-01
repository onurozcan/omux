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

    func testAntigravityIdentitySurvivesRoundTrip() throws {
        var group = TabGroup(name: "Project")
        group.provider = .antigravity
        group.command = "agy"
        var tab = TabItem(name: "Antigravity")
        tab.antigravityConversationID = "conv-12345"
        group.tabs = [tab]
        let restored = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(restored.tabs[0].resolvedProvider(in: restored), .antigravity)
        XCTAssertEqual(restored.tabs[0].antigravityConversationID, tab.antigravityConversationID)
    }

    func testCustomCommandsRemainCustom() {
        for command in ["env codex", "codex exec task", "npm run dev", "/path/to/wrapper", "env agy"] {
            XCTAssertEqual(SessionProvider.infer(command: command), .custom)
        }
    }

    func testAntigravityInference() {
        XCTAssertEqual(SessionProvider.infer(command: "agy"), .antigravity)
        XCTAssertEqual(SessionProvider.infer(command: "agy --model flash"), .antigravity)
        XCTAssertEqual(SessionProvider.infer(command: "antigravity"), .antigravity)
        XCTAssertEqual(SessionProvider.infer(command: "antigravity --model flash"), .antigravity)
    }

    func testClaudeStartsANewPinnedConversationInsteadOfContinuingAnotherTab() {
        let id = UUID()
        XCTAssertEqual(SessionProvider.claudeCommand("claude --model opus", sessionID: id, conversationExists: false),
                       "claude --session-id \(id.uuidString.lowercased()) --model opus")
        XCTAssertEqual(SessionProvider.claudeCommand("claude", sessionID: id, conversationExists: true),
                       "claude --resume \(id.uuidString.lowercased())")
    }

    func testAntigravityCommandResumesConversationWhenExists() {
        XCTAssertEqual(SessionProvider.antigravityCommand("agy", conversationID: "conv-1", conversationExists: true),
                       "agy --conversation conv-1")
        XCTAssertEqual(SessionProvider.antigravityCommand("agy --model flash", conversationID: "conv-1", conversationExists: true),
                       "agy --conversation conv-1 --model flash")
        XCTAssertEqual(SessionProvider.antigravityCommand("agy", conversationID: "conv-1", conversationExists: false),
                       "agy")
        XCTAssertEqual(SessionProvider.antigravityCommand("agy --continue", conversationID: "conv-1", conversationExists: true),
                       "agy --continue")
        XCTAssertEqual(SessionProvider.antigravityCommand("agy -c", conversationID: "conv-1", conversationExists: true),
                       "agy -c")
        XCTAssertEqual(SessionProvider.antigravityCommand("agy --conversation other", conversationID: "conv-1", conversationExists: true),
                       "agy --conversation other")
    }

    func testExplicitClaudeSessionFlagsArePreserved() {
        for raw in ["claude --resume abc", "claude --resume=abc", "claude --session-id=abc", "claude --continue"] {
            XCTAssertEqual(SessionProvider.claudeCommand(raw, sessionID: UUID(), conversationExists: false), raw)
        }
    }

    func testAgentsDoNotStartOnTheirOwnInTheHomeFolder() {
        let home = "/Users/me"
        for provider in [SessionProvider.claude, .codex, .antigravity] {
            XCTAssertFalse(provider.startsAutomatically(in: "/Users/me", home: home))
            XCTAssertFalse(provider.startsAutomatically(in: "/Users/me/", home: home))
            XCTAssertFalse(provider.startsAutomatically(in: "/Users/me/app/..", home: home))
            XCTAssertTrue(provider.startsAutomatically(in: "/Users/me/app", home: home))
        }
    }

    func testTildeMeansTheHomeFolder() {
        XCTAssertFalse(SessionProvider.claude.startsAutomatically(in: "~"))
        XCTAssertTrue(SessionProvider.claude.startsAutomatically(in: "~/app"))
    }

    func testShellsAndCustomCommandsStillStartInTheHomeFolder() {
        XCTAssertTrue(SessionProvider.shell.startsAutomatically(in: "/Users/me", home: "/Users/me"))
        XCTAssertTrue(SessionProvider.custom.startsAutomatically(in: "/Users/me", home: "/Users/me"))
    }
}
