import WebKit
import XCTest
@testable import omux

/// The file editor's Save path against the real editor page, in a web view that is never put in
/// a window.
final class CodeEditorSaveTests: XCTestCase {
    /// Passes the page's messages to the coordinator, keeping the dirty reports it sends.
    private final class Recorder: NSObject, WKScriptMessageHandler {
        let coordinator: CodeEditorView.Coordinator
        var dirty: [Bool] = []
        init(_ coordinator: CodeEditorView.Coordinator) { self.coordinator = coordinator }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], body["type"] as? String == "dirty" {
                dirty.append(body["dirty"] as? Bool ?? false)
            }
            coordinator.userContentController(controller, didReceive: message)
        }
    }

    /// Save writes what the page holds when it's clicked, also text typed after the last ⌘S.
    @MainActor
    func testSaveWritesWhatThePageHoldsNow() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)

        // As CodeEditorView.makeNSView wires it, with the page from the source tree.
        let document = FileDocument(url: file)
        let coordinator = CodeEditorView.Coordinator(document: document) { _ in }
        let recorder = Recorder(coordinator)
        let config = WKWebViewConfiguration()
        config.processPool = OmuxWebKit.pool
        config.userContentController.add(recorder, name: "omux")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        view.navigationDelegate = coordinator
        coordinator.webView = view
        document.editor = coordinator
        defer { config.userContentController.removeScriptMessageHandler(forName: "omux") }
        let pages = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/transcript", isDirectory: true).standardizedFileURL
        view.loadFileURL(pages.appendingPathComponent("editor.html"), allowingReadAccessTo: pages)
        // updateNSView: held as pending until the page says it's ready, then loaded.
        coordinator.update(text: document.text, generation: document.generation, language: nil, wrap: false, theme: .dark)

        try await waitUntil { (try? await self.pageText(view)) == "one" }

        try await type("one two", in: view)
        try await waitUntil { document.dirty }

        // The Save button.
        document.saveEditorText()
        try await waitUntil { (try? String(contentsOf: file, encoding: .utf8)) == "one two" }
        XCTAssertFalse(document.dirty)
        try await waitUntil { recorder.dirty.last == false }
        XCTAssertEqual(recorder.dirty.last, false, "the page reports clean after markSaved")

        // Typed again, no ⌘S: Save must write this, not the text from the last ⌘S.
        try await type("one two three", in: view)
        try await waitUntil { document.dirty && recorder.dirty.last == true }
        document.saveEditorText()
        try await waitUntil { (try? String(contentsOf: file, encoding: .utf8)) == "one two three" }
        XCTAssertFalse(document.dirty)
        try await waitUntil { recorder.dirty.last == false }
        XCTAssertEqual(recorder.dirty.last, false)
    }

    @MainActor
    private func type(_ text: String, in view: WKWebView) async throws {
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: [text]), as: UTF8.self)
        _ = try await view.evaluateJavaScript("""
            (function () { const input = document.getElementById('input');
              input.value = \(literal)[0]; input.dispatchEvent(new Event('input')); return true; })()
            """)
    }

    @MainActor
    private func pageText(_ view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript("window.editor ? editor.text() : null") as? String
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
