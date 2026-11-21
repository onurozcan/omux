import AppKit

/// Pictures people give their projects, shown on the rail in place of the initials. Each is
/// a small PNG copy kept in omux's own folder, so moving or deleting the original does not
/// empty the rail.
enum ProjectIcons {
    /// The longest side of a stored picture, in pixels: twice the tile, so it stays sharp on Retina.
    static let side: CGFloat = 128

    static var directory: URL {
        let dir = Persistence.directory.appendingPathComponent("project-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func image(named file: String?) -> NSImage? {
        guard let file, !file.isEmpty, file == (file as NSString).lastPathComponent else { return nil }
        if let cached = cache.object(forKey: file as NSString) { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        cache.setObject(image, forKey: file as NSString)
        return image
    }

    /// A square PNG of the picture at `url`, cropped from the middle, as data. nil when the file is not an image.
    static func squarePNG(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return squarePNG(from: data)
    }

    static func squarePNG(from data: Data) -> Data? {
        guard let source = NSImage(data: data), let rep = source.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let width = CGFloat(rep.pixelsWide), height = CGFloat(rep.pixelsHigh)
        let edge = min(width, height)
        let crop = NSRect(x: (width - edge) / 2, y: (height - edge) / 2, width: edge, height: edge)
        let target = NSSize(width: min(side, edge), height: min(side, edge))
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target), from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }

    /// Stores PNG data under a new name and returns the name. A new name each time, so the rail never shows a cached older picture.
    static func save(_ png: Data) -> String? {
        let name = UUID().uuidString.lowercased() + ".png"
        do { try png.write(to: directory.appendingPathComponent(name), options: .atomic) } catch { return nil }
        return name
    }

    static func remove(_ file: String?) {
        guard let file, file == (file as NSString).lastPathComponent else { return }
        cache.removeObject(forKey: file as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }

    /// Asks for a picture and returns it cropped and shrunk, or nil when none was chosen.
    @MainActor static func choose() -> Data? {
        let panel = NSOpenPanel()
        panel.title = "Choose a project icon"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return squarePNG(from: url)
    }

    // MARK: From a website

    /// The icon of a website, cropped and shrunk like a chosen picture; nil when the site has
    /// none omux can read. Asks only the site named, and only when the user presses Fetch:
    /// its home page for the icons it declares, then the two usual addresses.
    static func fetch(site: String) async -> Data? {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let base = URL(string: text), let scheme = base.scheme?.lowercased(), scheme == "https" || scheme == "http",
              base.host?.isEmpty == false else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await session.data(from: base), data.count <= 2_000_000 {
            // The page it ended on, after redirects: its links are relative to that.
            candidates = declared(in: String(decoding: data, as: UTF8.self), base: response.url ?? base)
        }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let url = URL(string: path, relativeTo: base)?.absoluteURL { candidates.append(url) }
        }
        for url in candidates.prefix(6) {
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let (data, _) = try? await session.data(from: url), data.count <= 2_000_000,
                  let png = squarePNG(from: data) else { continue }
            return png
        }
        return nil
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// The icons a page declares in its `<link rel="…icon…">` tags, the largest first; a touch
    /// icon counts as 180 pixels when it gives no size, a plain one as 32.
    static func declared(in html: String, base: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        func attribute(_ name: String, in tag: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
            for group in 1...3 { if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) } }
            return nil
        }
        var found: [(url: URL, size: Int)] = []
        let head = String(html.prefix(200_000))
        for match in tags.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let range = Range(match.range, in: head) else { continue }
            let tag = String(head[range])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href", in: tag), !href.hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let stated = attribute("sizes", in: tag).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") }
            found.append((url, stated ?? (rel.contains("apple") ? 180 : 32)))
        }
        return found.sorted { $0.size > $1.size }.map(\.url)
    }
}
