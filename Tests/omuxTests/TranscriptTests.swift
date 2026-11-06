import XCTest
@testable import omux

/// The transcript parser against records shaped like Claude Code 2.1's. A change in the
/// format shows up here before it shows up as a blank page.
@MainActor
final class TranscriptTests: XCTestCase {
    private func model() -> SessionTranscript {
        SessionTranscript(tab: TabItem(name: "t"), provider: .custom, claudeFile: { nil }, codexThread: { nil })
    }

    private func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testTurnsToolsAndResults() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#),
            object(#"{"type":"assistant","timestamp":"2026-11-04T10:00:03.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":100,"output_tokens":40},"content":[{"type":"thinking","thinking":"look first"},{"type":"text","text":"Reading the file."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/a.swift"}}]}}"#),
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:04.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"let x = 1"}]}}"#),
            object(#"{"type":"assistant","timestamp":"2026-11-04T10:00:09.000Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":10},"content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"pending"}]}}]}}"#),
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:20.000Z","message":{"role":"user","content":"thanks"}}"#),
        ])
        let kinds = m.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.user, .thinking, .assistant, .tools, .todos, .note, .user])
        XCTAssertEqual(m.blocks[3].tools.first?.result, "let x = 1")
        XCTAssertEqual(m.blocks[3].tools.first?.path, "/tmp/a.swift")
        XCTAssertEqual(m.blocks[4].todos.map(\.status), ["completed", "pending"])
        XCTAssertEqual(m.blocks[5].text, "Worked for 9s")
        XCTAssertEqual(m.blocks[2].model, "claude-opus-5-5")
        XCTAssertEqual(m.blocks[2].tokensIn, 102)
        XCTAssertEqual(m.totalOut, 50)
    }

    func testQueueRecordsFollowClaudeCodesQueue() {
        let m = model()
        m.ingest([object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"start"}}"#)])
        // Sent from the compose box while the agent worked, then recorded by Claude Code.
        m.echo("polish settings", queued: true)
        XCTAssertEqual(m.blocks[1].pending, "queuing", "on its way until Claude Code records it")
        m.ingest([object(#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-04T10:00:05.000Z","content":"polish settings"}"#)])
        XCTAssertEqual(m.blocks.filter { $0.kind == .user }.count, 2, "the record matches the echo instead of adding a bubble")
        XCTAssertEqual(m.blocks[1].pending, "queued")
        // Typed straight into the terminal: no echo, so the record makes the bubble.
        m.ingest([object(#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-04T10:00:06.000Z","content":"and the icon"}"#)])
        XCTAssertEqual(m.blocks[2].text, "and the icon")
        XCTAssertEqual(m.blocks[2].pending, "queued")
        // Taken in the middle of the turn: a real prompt now, and no user record will follow.
        m.ingest([object(#"{"type":"queue-operation","operation":"remove","reason":"absorbed_mid_turn","timestamp":"2026-11-04T10:00:07.000Z","content":"polish settings"}"#)])
        XCTAssertNil(m.blocks[1].pending)
        XCTAssertEqual(m.promptCount, 2)
        // Taken together at the turn's end: one record stands for both.
        m.ingest([object(#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-04T10:00:08.000Z","content":"one more"}"#)])
        m.ingest([
            object(#"{"type":"queue-operation","operation":"popAll","content":"and the icon"}"#),
            object(#"{"type":"queue-operation","operation":"popAll","content":"one more"}"#),
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:30.000Z","message":{"role":"user","content":"and the icon\none more"}}"#),
        ])
        XCTAssertEqual(m.blocks[2].text, "and the icon\none more")
        XCTAssertNil(m.blocks[2].pending)
        XCTAssertEqual(m.blocks[3].pending, "removed")
        XCTAssertEqual(m.blocks.filter { $0.kind == .user && $0.pending == nil }.count, 3)
        // Injected content passes through the queue too and never shows.
        m.ingest([object(#"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x</task-notification>"}"#)])
        XCTAssertEqual(m.blocks.count, 4)
        // Read back long after the fact: a prompt taken one at a time resolves to its record whatever its age.
        let old = model()
        old.ingest([
            object(#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:00:05.000Z","content":"later please"}"#),
            object(#"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-01T10:02:00.000Z"}"#),
            object(#"{"type":"user","timestamp":"2026-11-01T10:02:00.500Z","message":{"role":"user","content":"later please"}}"#),
        ])
        XCTAssertEqual(old.blocks.filter { $0.kind == .user }.count, 1)
        XCTAssertNil(old.blocks.first?.pending)
    }

    func testPastedContentWrapperIsStripped() {
        let m = model()
        m.ingest([object(#"{"type":"user","message":{"role":"user","content":"look at this\n<pasted_content id=\"acec\">\nline one\nline two\n</pasted_content id=\"acec\">"}}"#)])
        XCTAssertEqual(m.blocks.first?.text, "look at this\nline one\nline two")
    }

    func testMCPHealthParsesTheCLIsList() {
        let output = """
        Checking MCP server health…

        claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected
        plugin:cloudflare:cloudflare: https://mcp.cloudflare.com/mcp (HTTP) - ! Needs authentication
        meta-ads: https://mcp.facebook.com/ads (HTTP) - ✘ Failed to connect — Server rejected the configured Authorization header (HTTP 401).
        xcode: xcrun mcpbridge - ✔ Connected
        """
        let health = AgentConfig.parseMCPHealth(output)
        XCTAssertEqual(health.count, 4)
        XCTAssertEqual(health["claude.ai Google Drive"]?.state, "on")
        XCTAssertEqual(health["plugin:cloudflare:cloudflare"], AgentConfig.Health(state: "ask", note: "Needs sign-in", target: "https://mcp.cloudflare.com/mcp"))
        XCTAssertEqual(health["meta-ads"]?.state, "off")
        XCTAssertEqual(health["meta-ads"]?.note, "Failed: Server rejected the configured Authorization header (HTTP 401).")
        XCTAssertEqual(health["xcode"]?.target, "xcrun mcpbridge")
        // Folded into the overview: servers the config doesn't list come from the CLI, with the right actions.
        let overview = AgentConfig.mcp(project: "/nonexistent/project", health: health)
        let cloudflare = overview.rows.first { $0.name == "plugin:cloudflare:cloudflare" }
        XCTAssertEqual(cloudflare?.actions, ["login"])
        XCTAssertEqual(cloudflare?.note, "plugin · Needs sign-in")
        XCTAssertEqual(overview.rows.first { $0.name == "meta-ads" }?.actions.first, "reconnect")
        XCTAssertEqual(overview.kind, "mcp")
    }

    func testImagePathsInPromptsBecomeThumbnails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omux-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("shot one.png")
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: file)
        let m = model()
        m.ingest([object(#"{"type":"user","message":{"role":"user","content":"why this? \"\#(file.path)\" /nonexistent/x.png and done"}}"#)])
        XCTAssertEqual(m.blocks.first?.text, "why this? /nonexistent/x.png and done")
        XCTAssertEqual(m.blocks.first?.images.count, 1)
        XCTAssertTrue(m.blocks.first?.images.first?.hasPrefix("data:image/jpeg;base64,") == true)
        // The echo matches the record: both are shown without the path.
        let e = model()
        e.echo("look \"\(file.path)\"", queued: false)
        XCTAssertEqual(e.blocks.first?.text, "look")
        e.ingest([object(#"{"type":"user","message":{"role":"user","content":"look \\\"\#(file.path)\\\""}}"#)])
        XCTAssertEqual(e.blocks.count, 1)
        XCTAssertNil(e.blocks.first?.pending)
    }

    func testCompactionSummaryFoldsInsteadOfBeingAPrompt() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"start"}}"#),
            object(#"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-04T10:30:00.000Z"}"#),
            object(#"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"2026-11-04T10:30:01.000Z","message":{"role":"user","content":"This session is being continued from a previous conversation.\n\nSummary:\n1. Primary Request"}}"#),
        ])
        XCTAssertEqual(m.blocks.map(\.kind), [.user, .note, .summary])
        XCTAssertEqual(m.promptCount, 1)
        XCTAssertTrue(m.blocks[2].text.hasPrefix("This session is being continued"))
    }

    func testHandOverKeepsTurnsAndWritesTheHandoff() {
        let m = SessionTranscript(tab: TabItem(name: "t"), provider: .claude, claudeFile: { nil }, codexThread: { nil })
        m.ingest([
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#),
            object(#"{"type":"assistant","timestamp":"2026-11-04T10:00:03.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":4},"content":[{"type":"text","text":"Done, see a.swift."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/a.swift","old_string":"x","new_string":"y"}}]}}"#),
        ])
        let doc = m.handoff(from: "Claude Code")
        XCTAssertTrue(doc.contains("**User:** fix the build"))
        XCTAssertTrue(doc.contains("**Claude Code:** Done, see a.swift."))
        XCTAssertTrue(doc.contains("- /tmp/a.swift"))
        XCTAssertTrue(doc.contains("Edit a.swift"))
        m.switchTo(.codex)
        XCTAssertEqual(m.blocks.map(\.kind), [.user, .assistant, .tools, .note])
        XCTAssertEqual(m.blocks.last?.text, "Continued with Codex, handed the conversation so far")
        XCTAssertTrue(m.loaded)
    }

    func testHandoffBackCoversOnlyTheTurnsSinceTheSwitch() {
        let m = SessionTranscript(tab: TabItem(name: "t"), provider: .claude, claudeFile: { nil }, codexThread: { nil })
        m.ingest([object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#)])
        m.switchTo(.codex)
        XCTAssertFalse(m.hasTurnsSinceSwitch)
        m.codexDelta(item: "m1", text: "Looking at the build.")
        XCTAssertTrue(m.hasTurnsSinceSwitch)
        let back = m.handoff(from: "Codex", recent: true)
        XCTAssertTrue(back.contains("**Codex:** Looking at the build."))
        XCTAssertFalse(back.contains("fix the build"))
        XCTAssertTrue(back.contains("since your last turn"))
        XCTAssertTrue(m.handoff(from: "Codex").contains("fix the build"))
    }

    func testTheLastRequestSkipsHandoffPromptsSoTheyDontNest() {
        let m = SessionTranscript(tab: TabItem(name: "t"), provider: .claude, claudeFile: { nil }, codexThread: { nil })
        m.ingest([
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#),
            object(#"{"type":"user","timestamp":"2026-11-04T10:01:00.000Z","message":{"role":"user","content":"Continue my work from a conversation with Codex in this folder. Read /tmp/h.md first. Then carry on from the last request: fix the build"}}"#),
        ])
        XCTAssertEqual(m.lastRequest, "fix the build")
        XCTAssertTrue(SessionTranscript.isHandoffPrompt("I continued this work with Claude Code in this folder since your last turn."))
        XCTAssertFalse(SessionTranscript.isHandoffPrompt("Continue the build fix"))
    }

    func testCodexDeltasStreamIntoOneReply() {
        let m = SessionTranscript(tab: TabItem(name: "t"), provider: .codex, claudeFile: { nil }, codexThread: { nil })
        m.codexDelta(item: "m1", text: "Hello")
        m.codexDelta(item: "m1", text: ", world")
        XCTAssertEqual(m.blocks.map(\.kind), [.assistant])
        XCTAssertEqual(m.blocks.last?.text, "Hello, world")
        m.codexDelta(item: "m2", text: "Next")
        XCTAssertEqual(m.blocks.count, 2)
        XCTAssertEqual(m.blocks.map(\.id), [0, 1])
    }

    func testPromptsTheAgentNeverTookComeBackToTheBox() {
        let m = SessionTranscript(tab: TabItem(name: "t"), provider: .codex, claudeFile: { nil }, codexThread: { nil })
        XCTAssertNil(m.takeUnsent())
        m.echo("Reply with just the word pong.", queued: false)
        XCTAssertEqual(m.blocks.last?.pending, "sent")
        XCTAssertEqual(m.takeUnsent(), "Reply with just the word pong.")
        XCTAssertEqual(m.blocks.last?.pending, "removed")
        XCTAssertNil(m.takeUnsent())
    }

    func testUpArrowHistoryComesFromTheConversationToo() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#),
            object(#"{"type":"user","timestamp":"2026-11-04T10:01:00.000Z","message":{"role":"user","content":"now the tests"}}"#),
        ])
        XCTAssertEqual(m.history, ["fix the build", "now the tests"])
        m.remember("/model opus")
        m.remember("now the tests")
        XCTAssertEqual(m.history, ["fix the build", "now the tests", "/model opus"])
    }

    func testARefusedRestartAsksOmuxToRestartOnlyWhenItJustHappened() {
        let m = model()
        let command = object(#"{"type":"user","timestamp":"2026-11-06T19:45:38.743Z","message":{"role":"user","content":"<command-name>/restart</command-name>\n            <command-message>restart</command-message>\n            <command-args></command-args>"}}"#)
        let refusal = object(#"{"type":"system","subtype":"local_command","timestamp":"2026-11-06T19:45:38.744Z","content":"<local-command-stdout>Can't restart while Remote Control is connected. To use the installed version, exit and start Claude Code again, then run /resume.</local-command-stdout>"}"#)
        // Read back from the file at load: history, nothing to do.
        m.ingest([command, refusal])
        XCTAssertEqual(m.restartAsked, 0)
        // The same refusal arriving live: omux restarts.
        m.ingest([command, refusal])
        XCTAssertEqual(m.restartAsked, 1)
        XCTAssertTrue(m.blocks.last?.text.contains("omux restarted it") == true)
    }

    func testRemoteControlStatusReplacesTheCommandNote() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","timestamp":"2026-11-06T06:09:00.000Z","message":{"role":"user","content":"<command-message>remote-control</command-message>\n<command-name>/remote-control</command-name>"}}"#),
            object(#"{"type":"system","subtype":"bridge_status","timestamp":"2026-11-06T06:09:09.914Z","content":"/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_1","url":"https://claude.ai/code/session_1"}"#),
        ])
        XCTAssertEqual(m.blocks.map(\.kind), [.note])
        XCTAssertEqual(m.blocks.last?.text, "/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_1")
        // Without the command, the status still shows, once.
        let n = model()
        let status = object(#"{"type":"system","subtype":"bridge_status","timestamp":"2026-11-06T06:09:09.914Z","content":"/remote-control is active · at https://claude.ai/code/session_1"}"#)
        n.ingest([status, status])
        XCTAssertEqual(n.blocks.count, 1)
    }

    func testInjectedRecordsBecomeNotesOrVanish() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","message":{"role":"user","content":"<task-notification><task-id>x</task-id><summary>Agent finished</summary></task-notification>"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name><command-message>clear</command-message>"}}"#),
            object(#"{"type":"user","isMeta":true,"message":{"role":"user","content":"reminder"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ignore</system-reminder>real prompt"}]}}"#),
            object(#"{"type":"system","subtype":"compact_boundary"}"#),
        ])
        XCTAssertEqual(m.blocks.map(\.kind), [.note, .note, .user, .note])
        XCTAssertEqual(m.blocks[0].text, "Agent finished")
        XCTAssertEqual(m.blocks[1].text, "Conversation cleared")
        XCTAssertEqual(m.blocks[2].text, "real prompt")
        XCTAssertEqual(m.blocks[3].text, "Context compacted")
    }

    func testEditsCarryTheirDiffAndQuestionsTheirOptions() {
        let m = model()
        m.ingest([
            object(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"e","name":"Edit","input":{"file_path":"/tmp/b.ts","old_string":"a","new_string":"b"}},{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}]}}"#),
        ])
        let rows = m.blocks[0].tools
        XCTAssertEqual(rows[0].old, "a"); XCTAssertEqual(rows[0].new, "b")
        XCTAssertEqual(rows[1].questions.first?.options, ["A", "B"])
        XCTAssertEqual(m.pendingTool?.id, "q")
    }

    func testSyntheticMessagesAreNotesAndCountNothing() {
        let m = model()
        m.ingest([
            object(#"{"type":"assistant","message":{"id":"s1","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"No response requested."}]}}"#),
            object(#"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":7},"content":[{"type":"text","text":"Hello."}]}}"#),
        ])
        XCTAssertEqual(m.blocks.map(\.kind), [.note, .assistant])
        XCTAssertEqual(m.blocks[0].text, "No response requested.")
        XCTAssertEqual(m.lastModel, "claude-opus-5-5")
        XCTAssertEqual(m.totalOut, 7)
    }

    func testSlashCommandsReadAsWhatTheyDid() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","message":{"role":"user","content":"<command-name>/effort</command-name><command-message>effort</command-message><command-args>max</command-args>"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set effort level to max (this session only): deepest reasoning</local-command-stdout>"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name><command-args>claude-fable-5-1</command-args>"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":"<command-name>/cost</command-name><command-args></command-args>"}}"#),
            object(#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Total cost: `$0.42`</local-command-stdout>"}}"#),
        ])
        XCTAssertEqual(m.blocks.map(\.text), ["Effort changed to max", "Model changed to claude-fable-5-1", "Total cost: $0.42"])
    }

    func testRevisionsMoveOnlyForBlocksThatChanged() {
        let m = model()
        m.ingest([
            object(#"{"type":"user","message":{"role":"user","content":"go"}}"#),
            object(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#),
        ])
        XCTAssertEqual(m.blocks.map(\.rev), [0, 0])
        let before = m.version
        m.ingest([object(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]}}"#)])
        XCTAssertEqual(m.blocks.map(\.rev), [0, 1])
        XCTAssertEqual(m.blocks[1].tools[0].result, "a.txt")
        XCTAssertGreaterThan(m.version, before)
        XCTAssertNil(m.pendingTool)
        // A page at `before` gets just the block that changed; a page with nothing gets everything.
        let delta = m.delta(since: before)!
        XCTAssertTrue(delta.hasPrefix("{\"full\":false,\"total\":2,"))
        XCTAssertTrue(delta.contains("\"rev\":1"))
        XCTAssertFalse(delta.contains("\"kind\":\"user\""))
        XCTAssertTrue(m.delta(since: -1)!.hasPrefix("{\"full\":true,\"total\":2,"))
        XCTAssertNil(m.delta(since: m.version))
    }

    func testOldHeavyContentIsTrimmedUnderTheCap() {
        let m = model()
        // 60 KB tool outputs, three hundred of them: well past the 8 MB ceiling.
        let big = String(repeating: "x", count: 60_000)
        var records: [[String: Any]] = [object(#"{"type":"user","message":{"role":"user","content":"go"}}"#)]
        for i in 0..<300 {
            records.append(object(#"{"type":"assistant","message":{"id":"m\#(i)","content":[{"type":"tool_use","id":"t\#(i)","name":"Bash","input":{"command":"run \#(i)"}}]}}"#))
            records.append(object("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t\(i)\",\"content\":\"line one\\n\(big)\"}]}}"))
        }
        m.ingest(records)
        let rows = m.blocks.flatMap(\.tools)
        XCTAssertEqual(rows.count, 300)
        XCTAssertTrue(rows.first!.trimmed, "the oldest row loses its output")
        XCTAssertNil(rows.first!.output)
        XCTAssertEqual(rows.first!.result, "line one", "its first line stays")
        XCTAssertFalse(rows.last!.trimmed, "the newest keeps its output")
        XCTAssertNotNil(rows.last!.output)
        let kept = m.delta(since: -1)!.utf8.count
        XCTAssertLessThan(kept, 9 << 20, "the whole conversation stays under the ceiling")
    }

    func testDialogCommandsAreToldApart() {
        XCTAssertTrue(TranscriptPanel.opensDialog("/mcp", provider: .claude))
        XCTAssertTrue(TranscriptPanel.opensDialog("/model", provider: .claude))
        XCTAssertFalse(TranscriptPanel.opensDialog("/model opus", provider: .claude))
        XCTAssertFalse(TranscriptPanel.opensDialog("/compact", provider: .claude))
        XCTAssertFalse(TranscriptPanel.opensDialog("/my-skill", provider: .claude))
        XCTAssertTrue(TranscriptPanel.opensDialog("/anything", provider: .codex))
    }
}
