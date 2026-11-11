import AppKit
import SwiftUI
import WebKit

/// One session's embedded browser. The web view outlives tab switches, like terminals.
@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let tabID: UUID
    let webView: WKWebView
    @Published var address = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var picking = false
    @Published private(set) var error: String?
    /// A short confirmation after an element was sent to the prompt.
    @Published var notice: String?
    private var observations: [NSKeyValueObservation] = []
    /// The address whose load failed, for Try Again: WebKit puts its url back to the last page.
    private var failedURL: URL?

    init(tabID: UUID) {
        self.tabID = tabID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "omuxPick")
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        observations = [
            webView.observe(\.canGoBack) { [weak self] view, _ in DispatchQueue.main.async { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in DispatchQueue.main.async { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in DispatchQueue.main.async { self?.isLoading = view.isLoading } },
            webView.observe(\.url) { [weak self] view, _ in
                DispatchQueue.main.async {
                    guard let self, let url = view.url else { return }
                    self.currentURL = url
                    self.address = url.absoluteString
                }
            },
        ]
    }

    /// Loads typed text; a bare "localhost:3000" or host gets http://.
    func load(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") { raw = "http://" + raw }
        guard let url = URL(string: raw) else { error = "That isn't a valid address."; return }
        error = nil
        address = raw
        webView.load(URLRequest(url: url))
    }

    /// Shows a local page; `folder` (the page's own, or the project's) is what it may read.
    func load(file url: URL, within folder: URL) {
        error = nil
        address = url.absoluteString
        webView.loadFileURL(url, allowingReadAccessTo: folder)
    }

    func reload() {
        if error != nil, let failedURL {
            load(failedURL.absoluteString)
        } else if currentURL == nil { load(address) } else { webView.reload() }
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "omuxPick")
    }

    // MARK: Element picker

    func togglePick() {
        if picking {
            webView.evaluateJavaScript("window.__omuxPick && window.__omuxPick.stop()")
            picking = false
        } else {
            guard currentURL != nil else { return }
            notice = nil
            picking = true
            webView.evaluateJavaScript(Self.pickScript) { [weak self] _, error in
                if error != nil { DispatchQueue.main.async { self?.picking = false } }
            }
            webView.window?.makeFirstResponder(webView)
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers script messages on the main thread.
        MainActor.assumeIsolated {
            // Any page can post to the handler: take a pick only while the user is picking,
            // and only from the page itself, not a frame inside it.
            guard picking, message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            received(body)
        }
    }

    private func received(_ body: [String: Any]) {
        picking = false
        guard body["cancel"] == nil else { return }
        // Typed into the terminal, and the page wrote them: no control characters.
        let selector = CheckLog.plain(body["selector"] as? String ?? "element")
        let html = body["html"] as? String ?? ""
        let css = body["css"] as? String ?? ""
        let page = CheckLog.plain(body["url"] as? String ?? address)
        let rect = CGRect(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                          width: body["width"] as? Double ?? 0, height: body["height"] as? Double ?? 0)
            .intersection(webView.bounds)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("omux-picks", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970 * 1000)), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let htmlURL = folder.appendingPathComponent("element.html")
        let source = "<!-- Picked in omux from \(page) -->\n<!-- Selector: \(selector) -->\n<!-- Computed styles:\n\(css)\n-->\n\(html)\n"
        try? source.write(to: htmlURL, atomically: true, encoding: .utf8)

        let finish: (URL?) -> Void = { [weak self] imageURL in
            guard let self else { return }
            var text = "The \(selector) element on \(page): HTML and computed styles in \(htmlURL.path)"
            if let imageURL { text += ", screenshot at \(imageURL.path)" }
            Store.shared.sendText(text + ". ", to: self.tabID, submit: false)
            self.notice = "Added \(selector) to the prompt"
        }
        guard rect.width >= 1, rect.height >= 1 else { finish(nil); return }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        webView.takeSnapshot(with: config) { image, _ in
            DispatchQueue.main.async {
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { finish(nil); return }
                let imageURL = folder.appendingPathComponent("element.png")
                finish((try? png.write(to: imageURL)) == nil ? nil : imageURL)
            }
        }
    }

    // MARK: Navigation

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { self.error = nil; self.picking = false }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        let failed = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        DispatchQueue.main.async { self.error = message; self.failedURL = failed }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.error = message }
    }

    /// Highlights the element under the pointer; a click posts its selector, HTML, the
    /// styles that matter and its box. Escape cancels.
    private static let pickScript = #"""
    (function () {
      if (window.__omuxPick) window.__omuxPick.stop();
      const box = document.createElement('div');
      const tag = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #22d3ee;background:rgba(34,211,238,0.12);border-radius:2px;display:none';
      tag.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#22d3ee;color:#0b0b0f;font:11px ui-monospace,Menlo,monospace;padding:2px 6px;border-radius:3px;display:none';
      document.documentElement.append(box, tag);
      const name = (el) => {
        let s = el.tagName.toLowerCase();
        if (el.id) s += '#' + el.id;
        const cls = [...el.classList].filter((c) => !c.includes(':')).slice(0, 3);
        if (cls.length) s += '.' + cls.join('.');
        return s;
      };
      const path = (el) => {
        const parts = [];
        for (let n = el; n && n.nodeType === 1 && parts.length < 4; n = n.parentElement) {
          if ((n === document.body || n === document.documentElement) && parts.length) break;
          parts.unshift(name(n));
          if (n.id) break;
        }
        return parts.join(' > ');
      };
      let current = null;
      const move = (e) => {
        const el = e.target;
        if (!(el instanceof Element)) return;
        current = el;
        const r = el.getBoundingClientRect();
        Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        tag.textContent = name(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
        Object.assign(tag.style, { display: 'block', left: Math.max(0, r.left) + 'px', top: Math.max(0, r.top - 20) + 'px' });
      };
      const PROPS = ['display', 'position', 'box-sizing', 'width', 'height', 'margin', 'padding', 'border', 'border-radius',
        'background-color', 'background-image', 'color', 'font-family', 'font-size', 'font-weight', 'line-height',
        'letter-spacing', 'text-align', 'gap', 'flex-direction', 'justify-content', 'align-items',
        'grid-template-columns', 'box-shadow', 'opacity', 'overflow'];
      const pick = (e) => {
        e.preventDefault();
        e.stopPropagation();
        const el = current || e.target;
        const cs = getComputedStyle(el);
        const css = PROPS.map((p) => p + ': ' + cs.getPropertyValue(p))
          .filter((l) => !/: (normal|none|auto|0px|static|visible|)$/.test(l)).join(';\n');
        const r = el.getBoundingClientRect();
        stop();
        window.webkit.messageHandlers.omuxPick.postMessage({
          selector: path(el), html: el.outerHTML.slice(0, 30000), css, url: location.href,
          x: r.left, y: r.top, width: r.width, height: r.height });
      };
      const block = (e) => { e.preventDefault(); e.stopPropagation(); };
      const key = (e) => {
        if (e.key !== 'Escape') return;
        stop();
        window.webkit.messageHandlers.omuxPick.postMessage({ cancel: true });
      };
      function stop() {
        document.removeEventListener('mousemove', move, true);
        document.removeEventListener('click', pick, true);
        document.removeEventListener('mousedown', block, true);
        document.removeEventListener('mouseup', block, true);
        document.removeEventListener('keydown', key, true);
        box.remove();
        tag.remove();
        window.__omuxPick = null;
      }
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', pick, true);
      document.addEventListener('mousedown', block, true);
      document.addEventListener('mouseup', block, true);
      document.addEventListener('keydown', key, true);
      window.__omuxPick = { stop };
    })();
    """#
}

/// WKUserContentController keeps its handlers alive; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Panel

struct BrowserPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var session: BrowserSession
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack)
                    .help("Back")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward)
                    .help("Forward")
                Button {
                    if session.isLoading { session.webView.stopLoading() } else { session.reload() }
                } label: { Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise") }
                    .help(session.isLoading ? "Stop" : "Reload")
                TextField("localhost:3000", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { session.load(session.address) }
                Button { session.togglePick() } label: {
                    Image(systemName: "scope")
                        .foregroundStyle(session.picking ? Color.accentColor : Color.secondary)
                }
                .disabled(session.currentURL == nil)
                .help("Pick an element to send to this session")
                Button { if let url = session.currentURL { NSWorkspace.shared.open(url) } } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .disabled(session.currentURL == nil)
                .help("Open in default browser")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }

            if session.picking {
                Text("Click an element to add it to the session prompt. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.1))
            }

            ZStack {
                WebViewHost(webView: session.webView)
                    .opacity(session.currentURL == nil ? 0 : 1)
                if let error = session.error {
                    message(title: "Couldn't load the page", detail: error, retry: true)
                } else if session.currentURL == nil {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notice = session.notice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    Text(notice).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { session.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(nsColor: theme.chrome))
            }
        }
        .background(Color(nsColor: theme.background))
        .onAppear { openMentionedServer() }
        .onChange(of: store.mentionedURLs) { _, _ in openMentionedServer() }
    }

    /// The first time the panel shows, it opens the server the session printed last.
    private func openMentionedServer() {
        guard session.currentURL == nil, session.address.isEmpty, let url = store.mentionedURLs.last else { return }
        session.load(url)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No page open").font(.headline)
            if store.mentionedURLs.isEmpty {
                Text("Type an address above. Local servers this session prints, like localhost:3000, open here by themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            } else {
                Text("Servers in this session's output:").font(.caption).foregroundStyle(.secondary)
                ForEach(store.mentionedURLs.suffix(5).reversed(), id: \.self) { url in
                    Button(url) { session.load(url) }.buttonStyle(.link)
                }
            }
        }
        .padding()
    }

    private func message(title: String, detail: String, retry: Bool) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
            if retry { Button("Try Again") { session.reload() }.controlSize(.small) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.background))
    }
}

/// Hosts a session's long-lived web view, reparenting it like TerminalHost.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
