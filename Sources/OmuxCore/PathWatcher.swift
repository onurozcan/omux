import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Wakes on changes to one path: appends and writes to a file, or entries added to, removed
/// from or renamed in a folder. Waiting costs nothing between changes; the handler runs on the
/// main actor. nil when the path can't be watched yet. A vnode dispatch source on macOS,
/// inotify on Linux.
@MainActor
public final class PathWatcher {
    public let path: String
    private let source: DispatchSourceProtocol

    public init?(path: String, directory: Bool = false, handler: @escaping @MainActor () -> Void) {
        #if canImport(Darwin)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let mask: DispatchSource.FileSystemEvent = directory ? [.write, .delete, .rename] : [.write, .extend, .delete, .rename]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        #else
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return nil }
        // A folder reports its entries, not writes inside its files, as the vnode source does.
        let events = directory
            ? IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF
            : IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF
        guard inotify_add_watch(fd, path, UInt32(events)) >= 0 else { close(fd); return nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            // The events themselves say nothing the handler needs: empty the queue and wake it once.
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(fd, &buffer, buffer.count) > 0 {}
            MainActor.assumeIsolated { handler() }
        }
        #endif
        source.setCancelHandler { close(fd) }
        source.resume()
        self.path = path
        self.source = source
    }

    deinit { source.cancel() }
}
