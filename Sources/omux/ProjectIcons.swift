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
        guard let source = NSImage(contentsOf: url), let rep = source.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
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
}
