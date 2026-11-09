import Foundation

/// Wakes on changes to one path: appends and writes to a file, or entries added to, removed
/// from or renamed in a folder. A vnode dispatch source, so waiting costs nothing between
/// changes; the handler runs on the main actor. nil when the path can't be opened yet.
@MainActor
final class PathWatcher {
    let path: String
    private let source: DispatchSourceFileSystemObject

    init?(path: String, directory: Bool = false, handler: @escaping @MainActor () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.path = path
        let mask: DispatchSource.FileSystemEvent = directory ? [.write, .delete, .rename] : [.write, .extend, .delete, .rename]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source.cancel() }
}
