import Foundation

/// Runs a command and collects what it printed. Done when the command exits, not when its
/// output closes: a hook, a dotfile or a `cmd &` can leave a background process holding the
/// pipes, and waiting for that one would block the caller for as long as it lives.
public enum ChildProcess {
    public struct Output {
        public var status: Int32
        public var out: Data
        public var err: Data
    }

    /// How long output may keep coming once the command has exited. With nothing else holding
    /// the pipes it ends at once, so this only costs time when something does.
    static let grace: TimeInterval = 0.5

    /// Runs `process`, set up but for its output, and waits. Past `timeout` seconds it is
    /// terminated, killed if it ignores that, and the result is a failure saying so.
    /// `mergingErrors` sends standard error into `out`, interleaved as printed.
    public static func run(_ process: Process, timeout: TimeInterval? = nil, mergingErrors: Bool = false) -> Output {
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = mergingErrors ? outPipe : errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return Output(status: -1, out: Data(), err: Data(error.localizedDescription.utf8)) }
        // Both pipes are read while it runs: a full pipe would otherwise block it for good
        // (a chatty commit hook fills 64 KB fast).
        let reading = DispatchGroup()
        let readers = [Reader(outPipe, group: reading)] + (mergingErrors ? [] : [Reader(errPipe, group: reading)])
        let timedOut = exited.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // Bounded too: Linux's Foundation sees the exit only once every holder of a
                // descriptor the child inherited has closed it.
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = reading.wait(timeout: .now() + grace)
        readers.forEach { $0.stop() }
        reading.wait()
        if timedOut {
            return Output(status: -1, out: readers[0].data, err: Data("Timed out after \(String(format: "%g", timeout ?? 0)) seconds".utf8))
        }
        return Output(status: process.terminationStatus, out: readers[0].data, err: mergingErrors ? Data() : readers[1].data)
    }

    /// Reads one pipe as data comes, until its end or `stop()`.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var collected = Data()
        private let source: DispatchSourceRead

        init(_ pipe: Pipe, group: DispatchGroup) {
            let fd = pipe.fileHandleForReading.fileDescriptor
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            group.enter()
            source.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 65536)
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    lock.withLock { collected.append(buffer, count: n) }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    source.cancel()
                }
            }
            // The pipe is held until the source is done with its descriptor.
            source.setCancelHandler { withExtendedLifetime(pipe) { group.leave() } }
            source.resume()
        }

        func stop() { source.cancel() }

        var data: Data { lock.withLock { collected } }
    }
}
