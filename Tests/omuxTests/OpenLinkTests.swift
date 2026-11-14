import AppKit
import ObjectiveC
import XCTest
@testable import omux
@testable import OmuxCore

private var opened: [URL] = []
private var revealed: [URL] = []
extension NSWorkspace {
    @objc fileprivate func recordOpen(_ url: URL) -> Bool { opened.append(url); return true }
    @objc fileprivate func recordReveal(_ urls: [URL]) { revealed.append(contentsOf: urls) }
}

final class OpenLinkTests: XCTestCase {
    /// ⌘-click on `setup.command:3` or an app bundle used to reach SwiftTerm's default
    /// handler, which opened it: Terminal ran the script, the app launched. Locations now
    /// go to the preview and folders to Finder. NSWorkspace only records here.
    @MainActor
    func testLocationsPreviewAndBundlesAreOnlyShown() throws {
        var restore: [() -> Void] = []
        for (name, mine) in [("openURL:", #selector(NSWorkspace.recordOpen(_:))),
                             ("activateFileViewerSelectingURLs:", #selector(NSWorkspace.recordReveal(_:)))] {
            let original = try XCTUnwrap(class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString(name)))
            let replacement = try XCTUnwrap(class_getInstanceMethod(NSWorkspace.self, mine))
            method_exchangeImplementations(original, replacement)
            restore.append { method_exchangeImplementations(original, replacement) }
        }
        defer { restore.forEach { $0() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = dir.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("setup.command")
        try ":\n".write(to: script, atomically: true, encoding: .utf8)

        let view = TermView(tabID: UUID())
        var previews: [String] = []
        view.onEvent = { if case .openPath(let path) = $0 { previews.append(path) } }
        for link in [script.path + ":3", script.path + ":3:1", app.path, "file://" + app.path] {
            view.requestOpenLink(source: view, link: link, params: [:])
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(opened, [])
        XCTAssertEqual(previews, [script.path, script.path])
        XCTAssertEqual(revealed.count, 2)
    }

    /// A web address clicked in a session opens in that session's browser, not in the
    /// default browser in another window. Only http and https count as web addresses.
    @MainActor
    func testWebAddressesGoToTheSessionsBrowser() {
        let view = TermView(tabID: UUID())
        var links: [URL] = []
        view.onEvent = { if case .openLink(let url) = $0 { links.append(url) } }
        view.requestOpenLink(source: view, link: "https://example.com/docs?page=2", params: [:])
        view.requestOpenLink(source: view, link: " http://localhost:3000 ", params: [:])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/docs?page=2", "http://localhost:3000"])

        XCTAssertNotNil(TermView.webURL(from: "HTTPS://Example.com"))
        for other in ["mailto:someone@example.com", "file:///etc/hosts", "javascript:alert(1)", "ssh://host", "https://", "not a link"] {
            XCTAssertNil(TermView.webURL(from: other), other)
        }
    }
}
