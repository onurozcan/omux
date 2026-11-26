import Foundation

/// What the `omux` command line tool and the app say to each other: one JSON request line
/// on a Unix socket only this user can open, one JSON response line back.
public struct CLIRequest: Codable, Equatable {
    /// The session's own token, which the app put in its environment (OMUX_TOKEN).
    public var token: String
    /// The session the command runs from (OMUX_TAB_ID).
    public var from: String
    public var command: String
    /// A session id or name; nil means the calling session.
    public var target: String?
    public var text: String?
    public var submit: Bool?
    public var lines: Int?
    public var name: String?
    public var directory: String?
    public var provider: String?

    public init(token: String = "", from: String = "", command: String, target: String? = nil, text: String? = nil,
                submit: Bool? = nil, lines: Int? = nil, name: String? = nil, directory: String? = nil, provider: String? = nil) {
        self.token = token; self.from = from; self.command = command; self.target = target; self.text = text
        self.submit = submit; self.lines = lines; self.name = name; self.directory = directory; self.provider = provider
    }
}

public struct CLISession: Codable, Equatable {
    public var id: String
    public var name: String
    public var provider: String
    /// idle, working, done, blocked or error from the agent; "running" for a shell with no
    /// agent status; "stopped" when nothing runs in the session.
    public var state: String
    /// Why a blocked agent waits: permission, question or auth.
    public var kind: String?
    public var message: String?
    public var directory: String?
    /// The calling session.
    public var isSelf: Bool
    /// Started by the calling session with `omux new`, so it may be steered and closed.
    public var isChild: Bool

    public init(id: String, name: String, provider: String, state: String, kind: String? = nil, message: String? = nil,
                directory: String? = nil, isSelf: Bool = false, isChild: Bool = false) {
        self.id = id; self.name = name; self.provider = provider; self.state = state; self.kind = kind
        self.message = message; self.directory = directory; self.isSelf = isSelf; self.isChild = isChild
    }
}

public struct CLIResponse: Codable, Equatable {
    public var ok: Bool
    public var error: String?
    public var sessions: [CLISession]?
    public var session: CLISession?
    public var screen: [String]?

    public init(ok: Bool, error: String? = nil, sessions: [CLISession]? = nil, session: CLISession? = nil, screen: [String]? = nil) {
        self.ok = ok; self.error = error; self.sessions = sessions; self.session = session; self.screen = screen
    }

    public static func failure(_ message: String) -> CLIResponse { CLIResponse(ok: false, error: message) }
}

public struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The tool's command line, parsed. `wait` is served by the tool itself, polling `status`.
public enum CLICommand: Equatable {
    case help
    case list
    case status(target: String?)
    case screen(target: String?, lines: Int)
    case send(target: String, text: String, submit: Bool)
    case new(name: String?, directory: String?, provider: String?)
    case close(target: String)
    case wait(target: String?, states: [String], timeout: Int)

    public static let defaultScreenLines = 40
    public static let maxScreenLines = 500
    public static let waitStates = ["idle", "working", "done", "blocked", "error", "running", "stopped"]
}

public enum CLIArguments {
    public static let usage = """
    omux — talk to the omux session this command runs in

    omux list                         sessions of this project, with their state
    omux status [session]             one session's state (default: this one)
    omux screen [session] [-n LINES]  the last lines on a session's screen (default 40, max 500)
    omux send SESSION TEXT… [--submit] type text into a session you started; --submit presses Return
    omux send SESSION - [--submit]    the text comes from stdin
    omux new [--name NAME] [--dir DIR] [--provider claude|codex|shell]
                                      start a session in this project; prints its id
    omux close SESSION                close a session you started
    omux wait [session] [--for STATE,…] [--timeout SECONDS]
                                      block until the session reaches one of the states
                                      (default: blocked,done,error,stopped; timeout 600)
    omux --json …                     machine-readable output

    A session is addressed by its id or its exact name. Sessions can read every session of
    their project, and send text to and close only the sessions they started themselves.
    """

    public static func parse(_ arguments: [String]) -> Result<(command: CLICommand, json: Bool), CLIUsageError> {
        var args = arguments
        var json = false
        if let i = args.firstIndex(of: "--json") { json = true; args.remove(at: i) }
        guard let first = args.first else { return .success((.help, json)) }
        let rest = Array(args.dropFirst())
        func value(_ flag: String, in list: inout [String]) -> Result<String?, CLIUsageError> {
            guard let i = list.firstIndex(of: flag) else { return .success(nil) }
            guard i + 1 < list.count else { return .failure(CLIUsageError("\(flag) needs a value")) }
            let v = list[i + 1]
            list.removeSubrange(i...(i + 1))
            return .success(v)
        }
        switch first {
        case "help", "--help", "-h": return .success((.help, json))
        case "list":
            guard rest.isEmpty else { return .failure(CLIUsageError("list takes no arguments")) }
            return .success((.list, json))
        case "status":
            guard rest.count <= 1 else { return .failure(CLIUsageError("status takes at most one session")) }
            return .success((.status(target: rest.first), json))
        case "screen":
            var list = rest
            var lines = CLICommand.defaultScreenLines
            switch value("-n", in: &list) {
            case .failure(let e): return .failure(e)
            case .success(let v):
                if let v {
                    guard let n = Int(v), n >= 1 else { return .failure(CLIUsageError("-n needs a number of lines")) }
                    lines = min(n, CLICommand.maxScreenLines)
                }
            }
            guard list.count <= 1 else { return .failure(CLIUsageError("screen takes at most one session")) }
            return .success((.screen(target: list.first, lines: lines), json))
        case "send":
            var list = rest
            var submit = false
            if let i = list.firstIndex(of: "--submit") { submit = true; list.remove(at: i) }
            guard let target = list.first else { return .failure(CLIUsageError("send needs a session and text")) }
            let text = list.dropFirst().joined(separator: " ")
            guard !text.isEmpty else { return .failure(CLIUsageError("send needs text, or - to read it from stdin")) }
            return .success((.send(target: target, text: text, submit: submit), json))
        case "new":
            var list = rest
            var name: String?, dir: String?, provider: String?
            for (flag, slot) in [("--name", 0), ("--dir", 1), ("--provider", 2)] {
                switch value(flag, in: &list) {
                case .failure(let e): return .failure(e)
                case .success(let v):
                    switch slot { case 0: name = v; case 1: dir = v; default: provider = v }
                }
            }
            if let provider, !["claude", "codex", "shell"].contains(provider) {
                return .failure(CLIUsageError("--provider is claude, codex or shell"))
            }
            guard list.isEmpty else { return .failure(CLIUsageError("new doesn't take \(list.joined(separator: " "))")) }
            return .success((.new(name: name, directory: dir, provider: provider), json))
        case "close":
            guard rest.count == 1 else { return .failure(CLIUsageError("close takes one session")) }
            return .success((.close(target: rest[0]), json))
        case "wait":
            var list = rest
            var states = ["blocked", "done", "error", "stopped"]
            var timeout = 600
            switch value("--for", in: &list) {
            case .failure(let e): return .failure(e)
            case .success(let v):
                if let v {
                    states = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if let bad = states.first(where: { !CLICommand.waitStates.contains($0) }) {
                        return .failure(CLIUsageError("unknown state \(bad); states are \(CLICommand.waitStates.joined(separator: ", "))"))
                    }
                }
            }
            switch value("--timeout", in: &list) {
            case .failure(let e): return .failure(e)
            case .success(let v):
                if let v {
                    guard let n = Int(v), n >= 1 else { return .failure(CLIUsageError("--timeout needs a number of seconds")) }
                    timeout = n
                }
            }
            guard list.count <= 1 else { return .failure(CLIUsageError("wait takes at most one session")) }
            return .success((.wait(target: list.first, states: states, timeout: timeout), json))
        default:
            return .failure(CLIUsageError("unknown command \(first); try omux help"))
        }
    }

    /// The request a command sends; `wait` sends `status` repeatedly.
    public static func request(for command: CLICommand) -> CLIRequest? {
        switch command {
        case .help: return nil
        case .list: return CLIRequest(command: "list")
        case .status(let target), .wait(let target, _, _): return CLIRequest(command: "status", target: target)
        case .screen(let target, let lines): return CLIRequest(command: "screen", target: target, lines: lines)
        case .send(let target, let text, let submit): return CLIRequest(command: "send", target: target, text: text, submit: submit)
        case .new(let name, let directory, let provider): return CLIRequest(command: "new", name: name, directory: directory, provider: provider)
        case .close(let target): return CLIRequest(command: "close", target: target)
        }
    }
}
