import Foundation

/// What the app, or the `omux-host` command, and a session host say to each other.
///
/// The host owns the sessions: it starts them, keeps them running with nobody attached, and
/// remembers what each has printed. A client is a view. It asks for the sessions, attaches to
/// the ones it shows, and after a dropped connection says how much it already has, to be sent
/// only the rest.
public enum HostProtocol {
    /// Raised when a message changes meaning. Both sides say theirs first; additions that an
    /// older side can ignore don't raise it.
    public static let version = 1
}

/// One session a host runs.
public struct SessionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var directory: String
    /// The program and its arguments.
    public var command: [String]
    public var started: Date
    public var columns: Int
    public var rows: Int
    /// How many bytes the session has printed so far: where its output ends.
    public var outputEnd: UInt64
    /// Its exit code once it has ended. An ended session stays listed until it is closed.
    public var exited: Int32?
}

public struct StartRequest: Codable, Equatable, Sendable {
    public var name: String?
    /// The folder to start in; the host's home folder when nil.
    public var directory: String?
    /// The program and its arguments; the user's login shell when empty.
    public var command: [String]
    /// Added to the host's own environment.
    public var environment: [String: String]
    public var columns: Int
    public var rows: Int

    public init(name: String? = nil, directory: String? = nil, command: [String] = [], environment: [String: String] = [:], columns: Int = 80, rows: Int = 24) {
        self.name = name; self.directory = directory; self.command = command; self.environment = environment; self.columns = columns; self.rows = rows
    }
}

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(version: Int)
    case list
    case start(StartRequest)
    /// Output from byte `from` on, then everything new as it comes; nil asks for all the host
    /// still holds. A session can be attached to by any number of clients.
    case attach(session: String, from: UInt64?)
    case detach(session: String)
    case input(session: String, data: Data)
    case resize(session: String, columns: Int, rows: Int)
    /// Hangs up on a running session; removes one that has ended.
    case close(session: String)
}

public enum HostMessage: Codable, Equatable, Sendable {
    case welcome(version: Int, host: String, system: String)
    case sessions([SessionInfo])
    case started(SessionInfo)
    /// Bytes the session printed, starting at byte `offset` of its output. A client that adds
    /// each chunk's length to its offset knows what to ask for after a reconnect.
    case output(session: String, offset: UInt64, data: Data)
    case exited(session: String, code: Int32)
    case done
    case failed(String)
}

/// A request, numbered so its answer can be told from the output streaming alongside it.
public struct ClientFrame: Codable, Equatable, Sendable {
    public var id: Int
    public var message: ClientMessage
    public init(id: Int, message: ClientMessage) { self.id = id; self.message = message }
}

/// An answer to request `reply`, or with no number, something the host says unasked: output
/// and exits of attached sessions.
public struct HostFrame: Codable, Equatable, Sendable {
    public var reply: Int?
    public var message: HostMessage
    public init(reply: Int? = nil, message: HostMessage) { self.reply = reply; self.message = message }
}
