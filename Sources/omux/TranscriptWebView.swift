import AppKit
import SwiftUI
import WebKit

/// The Transcript view's conversation, drawn by WebKit from Resources/transcript: markdown with
/// highlighted code, diffs on edits, foldable tool runs. Everything is local; the page can't
/// load anything from the network, and links go to the default browser.
/// The process pool every omux page shares: WebKit can then keep pages in one content process
/// and reuse the scripts it already parsed, so a second pane opens faster than the first.
enum OmuxWebKit {
    static let pool = WKProcessPool()
}

/// One page per slot: the single-session view has one, each pane has its own. A page outlives
/// the sessions it shows, so picking another session is a redraw inside a loaded page, not a
/// new WebKit process and a load. Each page is a content process, so there are few.
@MainActor
final class TranscriptPages {
    static let shared = TranscriptPages()
    private static let limit = 8

    final class Page {
        let webView: WKWebView
        var loaded = false
        /// The session the page currently shows, and how far it has seen of it.
        var session: UUID?
        var sentVersion = -1
        var sentEnvelope: String?
        var themeJSON: String?
        var lastShown = Date()
        /// The coordinator drawing into the page now; an older one's teardown leaves it alone.
        weak var owner: AnyObject?
        /// Holds the delegate of a page loaded ahead of use.
        var warmer: AnyObject?
        init(webView: WKWebView) { self.webView = webView }
    }

    private var pages: [String: Page] = [:]

    func page(for slot: String) -> Page? {
        pages[slot]?.lastShown = Date()
        return pages[slot]
    }

    func isLoaded(_ slot: String) -> Bool { pages[slot]?.loaded == true }

    /// Loads a slot's page ahead of its first use, so the first session shown doesn't pay for
    /// the WebKit process and the page load. Called at launch for the single-session view.
    func warm(_ slot: String) {
        guard pages[slot] == nil else { return }
        let config = WKWebViewConfiguration()
        config.processPool = OmuxWebKit.pool
        config.preferences.isElementFullscreenEnabled = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.unregisterDraggedTypes()
        let page = Page(webView: view)
        let warmer = Warmer(page: page)
        page.warmer = warmer
        view.navigationDelegate = warmer
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("transcript", isDirectory: true) {
            view.loadFileURL(dir.appendingPathComponent("transcript.html"), allowingReadAccessTo: dir)
        }
        keep(page, for: slot)
    }

    /// Notes when a warmed page has loaded, until a pane takes it over.
    final class Warmer: NSObject, WKNavigationDelegate {
        let page: Page
        init(page: Page) { self.page = page }
        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { page.loaded = true }
        }
    }

    func keep(_ page: Page, for slot: String) {
        pages[slot] = page
        while pages.count > Self.limit, let oldest = pages.filter({ $0.key != "single" }).min(by: { $0.value.lastShown < $1.value.lastShown }) {
            oldest.value.webView.removeFromSuperview()
            pages[oldest.key] = nil
        }
    }

    func forget(_ slot: String) {
        pages[slot]?.webView.removeFromSuperview()
        pages[slot] = nil
    }

    /// Drops the pages of panes that no longer exist.
    func prune(keeping slots: Set<String>) {
        for slot in pages.keys where !slots.contains(slot) { forget(slot) }
    }
}

struct TranscriptWebView: NSViewRepresentable {
    /// The page to draw into, and the session to draw.
    let slot: String
    let tabID: UUID
    /// Where the blocks come from, and the version they're at; the page gets only what changed since it last saw.
    let model: SessionTranscript
    let blocksVersion: Int
    /// The rest of the page's input as JSON: status, agents, summary, notices.
    let envelope: String
    let theme: Theme
    var style = TranscriptStyle.current
    /// A click anywhere on the page, before the page handles it: selects the pane.
    var onClick: (() -> Void)? = nil
    /// A session dragged over the page: the edge it would land on, or nil when it leaves.
    var onDragEdge: ((Edge?) -> Void)? = nil
    /// A session dropped on the page, with the edge it landed on.
    var onDropSession: ((UUID, Edge) -> Void)? = nil
    /// Messages the page posts: changes, path, agent, send, quote, manage, config, rendered.
    let onMessage: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    /// The same drop-taking container the terminal sits in, so sessions dragged onto the
    /// page's edges split the pane. The web view gives up its own drag handling for that.
    func makeNSView(context: Context) -> TerminalHost.Container {
        let page: TranscriptPages.Page
        if let kept = TranscriptPages.shared.page(for: slot) {
            // The slot's page is still there; the next update redraws it for this session.
            page = kept
            page.webView.removeFromSuperview()
            page.webView.configuration.userContentController.removeScriptMessageHandler(forName: "omux")
            page.webView.configuration.userContentController.add(context.coordinator, name: "omux")
            page.webView.navigationDelegate = context.coordinator
            page.warmer = nil
        } else {
            let config = WKWebViewConfiguration()
            config.processPool = OmuxWebKit.pool
            config.userContentController.add(context.coordinator, name: "omux")
            config.preferences.isElementFullscreenEnabled = false
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = context.coordinator
            view.setValue(false, forKey: "drawsBackground")
            view.allowsBackForwardNavigationGestures = false
            view.unregisterDraggedTypes()
            if let dir = Bundle.main.resourceURL?.appendingPathComponent("transcript", isDirectory: true) {
                view.loadFileURL(dir.appendingPathComponent("transcript.html"), allowingReadAccessTo: dir)
            }
            page = TranscriptPages.Page(webView: view)
            TranscriptPages.shared.keep(page, for: slot)
        }
        context.coordinator.page = page
        page.owner = context.coordinator
        let view = page.webView
        let container = TerminalHost.Container(frame: .zero)
        container.onClick = onClick
        container.onDragEdge = onDragEdge
        container.onDropSession = onDropSession
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
        return container
    }

    func updateNSView(_ container: TerminalHost.Container, context: Context) {
        container.onClick = onClick
        container.onDragEdge = onDragEdge
        container.onDropSession = onDropSession
        context.coordinator.update(model: model, envelope: envelope, theme: theme, style: style)
    }

    static func dismantleNSView(_ container: TerminalHost.Container, coordinator: Coordinator) {
        // The page stays for the slot; only this pane's hooks let go of it, and only while this
        // pane still owns it: SwiftUI builds the next pane before it tears down this one.
        guard let page = coordinator.page else { return }
        page.lastShown = Date()
        guard page.owner === coordinator else { return }
        page.webView.configuration.userContentController.removeScriptMessageHandler(forName: "omux")
        page.webView.navigationDelegate = nil
        page.webView.removeFromSuperview()
        page.owner = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        /// The cached page this pane shows; what it has seen lives there, so a pane can come and go.
        var page: TranscriptPages.Page?
        var webView: WKWebView? { page?.webView }
        private let onMessage: ([String: Any]) -> Void
        private var pending: (model: SessionTranscript, envelope: String)?

        init(onMessage: @escaping ([String: Any]) -> Void) { self.onMessage = onMessage }

        /// The page gets the blocks that changed since it last saw, and the envelope when it
        /// changed; a status tick doesn't resend the conversation. A different session than the
        /// page shows starts over with everything.
        func update(model: SessionTranscript, envelope: String, theme: Theme, style: TranscriptStyle) {
            guard let page else { return }
            let themeJSON = Self.themeJSON(theme, style: style)
            if themeJSON != page.themeJSON {
                page.themeJSON = themeJSON
                if page.loaded { page.webView.evaluateJavaScript("omux.setTheme(\(themeJSON))") }
            }
            // Nothing goes to the page until both it and the conversation are ready: an empty
            // render followed by the real one would show as a load and a jump.
            guard page.loaded, model.loaded else { pending = (model, envelope); return }
            if page.session != model.tabID { page.session = model.tabID; page.sentVersion = -1; page.sentEnvelope = nil }
            let delta = model.delta(since: page.sentVersion)
            guard delta != nil || envelope != page.sentEnvelope else { return }
            page.sentVersion = model.version
            page.sentEnvelope = envelope
            send(blocks: delta, envelope: envelope, session: model.tabID)
        }

        private func send(blocks: String?, envelope: String, session: UUID) {
            // The envelope is a JSON object; the blocks and the session slot into it as its first members.
            let body = "{\"blocks\":" + (blocks ?? "null") + ",\"session\":\"\(session.uuidString)\"," + envelope.dropFirst()
            webView?.evaluateJavaScript("omux.render(\(body))")
        }

        private static func themeJSON(_ theme: Theme, style: TranscriptStyle) -> String {
            func hex(_ color: NSColor) -> String {
                let c = color.usingColorSpace(.sRGB) ?? color
                return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            }
            func luminance(_ color: NSColor) -> CGFloat {
                let c = color.usingColorSpace(.sRGB) ?? color
                return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            }
            let accent = Appearance.accent(style.accent, theme: theme)
            let accentSoft = (accent.usingColorSpace(.sRGB) ?? accent)
            let soft = String(format: "rgba(%d,%d,%d,0.16)", Int(accentSoft.redComponent * 255), Int(accentSoft.greenComponent * 255), Int(accentSoft.blueComponent * 255))
            let font = Fonts.terminal()
            let object: [String: Any] = [
                "bg": hex(theme.background), "fg": hex(theme.foreground), "accent": hex(accent), "accentSoft": soft,
                "dark": luminance(theme.background) < 0.5, "neutral": style.accent == "neutral",
                "mono": "'\(font.familyName ?? "Menlo")', ui-monospace, Menlo, monospace",
                "font": style.fontStack, "size": style.size, "width": style.width, "density": style.density,
                "bubbles": style.bubbles, "timestamps": style.timestamps,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                guard let page else { return }
                page.loaded = true
                if let themeJSON = page.themeJSON { webView.evaluateJavaScript("omux.setTheme(\(themeJSON))") }
                if let pending, pending.model.loaded {
                    page.session = pending.model.tabID
                    page.sentVersion = pending.model.version
                    page.sentEnvelope = pending.envelope
                    send(blocks: pending.model.delta(since: -1), envelope: pending.envelope, session: pending.model.tabID)
                    self.pending = nil
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            Task { @MainActor in
                guard let url = action.request.url else { decisionHandler(.cancel); return }
                if url.isFileURL { decisionHandler(.allow); return }
                if ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }

        // WebKit delivers script messages on the main thread.
        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
                switch type {
                case "open":
                    if let href = body["href"] as? String, let url = URL(string: href),
                       ["http", "https", "mailto"].contains(url.scheme ?? "") {
                        NSWorkspace.shared.open(url)
                    }
                case "copy":
                    if let text = body["text"] as? String {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                default:
                    onMessage(body)
                }
            }
        }
    }
}
