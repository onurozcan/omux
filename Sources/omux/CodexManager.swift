import Foundation
import SwiftUI

struct CodexApproval: Hashable, Identifiable {
    let id: CodexRequestID
    let threadID: String
    let turnID: String
    let method: String
    let detail: String

    init?(message: [String: Any]) {
        guard let method = message["method"] as? String,
              ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method),
              let id = CodexRequestID(message["id"]),
              let params = message["params"] as? [String: Any],
              let thread = params["threadId"] as? String,
              let turn = params["turnId"] as? String else { return nil }
        self.id = id; threadID = thread; turnID = turn; self.method = method
        detail = params["command"] as? String ?? params["reason"] as? String ?? "Approve file changes in Codex"
    }
}

struct CodexStatus: Equatable {
    let state: TabRuntime.StatusState
    var kind: String? = nil
    var detail: String? = nil

    static func decode(_ raw: [String: Any]) -> CodexStatus? {
        switch raw["type"] as? String {
        case "idle": return CodexStatus(state: .idle)
        case "active":
            let flags = raw["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") { return CodexStatus(state: .blocked, kind: "approval", detail: "Answer the approval request in Codex") }
            if flags.contains("waitingOnUserInput") { return CodexStatus(state: .blocked, kind: "question", detail: "Answer the question in Codex") }
            return CodexStatus(state: .working)
        case "systemError": return CodexStatus(state: .error, detail: "Codex reported an error")
        case "notLoaded": return CodexStatus(state: .idle, detail: "Conversation unloaded")
        default: return nil
        }
    }
}

/// The protocol client and TUI share an Omux-owned server per terminal. No global daemon is
/// stopped, and every operation is addressed to an exact thread or request ID.
@MainActor
final class CodexManager: ObservableObject {
    static let shared = CodexManager()
    private var connections: [UUID: CodexConnection] = [:]
    private let catalog = CodexConnection()
    var onThreadChange: ((UUID, String) -> Void)?
    var onStatus: ((UUID, CodexStatus) -> Void)?
    /// What a session's thread does, for the transcript showing it: items starting and
    /// completing, turns, and the reply's text as it streams in.
    enum TranscriptEvent { case item(id: String, type: String, completed: Bool), turn(completed: Bool), delta(item: String, text: String) }
    private var transcriptListeners: [UUID: (TranscriptEvent) -> Void] = [:]
    func listen(_ tabID: UUID, _ handler: ((TranscriptEvent) -> Void)?) { transcriptListeners[tabID] = handler }
    @Published private(set) var approvals: [String: [CodexApproval]] = [:]
    @Published private(set) var answering: Set<CodexApproval> = []
    @Published private(set) var limits: [UsageMonitor.Limit] = []
    @Published private(set) var usageError: String?
    /// The account's plan, like "free" or "plus", from the last usage read.
    @Published private(set) var plan: String?
    @Published private(set) var agents: [UUID: [CodexAgent]] = [:]
    private var agentOwners: [String: UUID] = [:]
    private var threads: [UUID: String] = [:]
    private var turns: [String: String] = [:]
    private var status: [String: CodexStatus] = [:]
    private var completedTurns: [String: String] = [:]
    private var quotaBucket: [String: Any] = [:]
    private var refreshingUsage = false
    private var retiring: [UUID: Task<Void, Error>] = [:]

    init() {}

    func register(tabID: UUID, threadID: String) { threads[tabID] = threadID }

    func connection(for tabID: UUID) -> CodexConnection {
        if let connection = connections[tabID] { return connection }
        let connection = CodexConnection()
        connections[tabID] = connection
        connection.onMessage = { [weak self] in self?.receive($0, owner: tabID) }
        connection.onDisconnect = { [weak self] in
            guard let self else { return }
            self.clearActivity(tabID)
            self.onStatus?(tabID, CodexStatus(state: .error, detail: CodexError.disconnected.localizedDescription))
        }
        return connection
    }

    /// `model` and `effort` are set on the thread here: the TUI attached over `--remote` runs
    /// turns with the thread's model, and its own `-c model=` flag doesn't reach it.
    func prepare(tabID: UUID, threadID: String?, cwd: String, name: String, model: String? = nil, effort: String? = nil) async throws -> (threadID: String, command: String) {
        let connection = connection(for: tabID)
        if let previous = retiring[tabID] {
            try await previous.value
            try Task.checkCancellation()
            retiring[tabID] = nil
        }
        try await connection.connect()
        try Task.checkCancellation()
        var params: [String: Any] = threadID.map { ["threadId": $0, "excludeTurns": true] } ?? ["cwd": cwd]
        if let model { params["model"] = model }
        if let effort { params["config"] = ["model_reasoning_effort": effort] }
        let response = try await connection.request(threadID == nil ? "thread/start" : "thread/resume", params: params)
        guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String,
              let endpoint = connection.endpoint else { throw CodexError.server("Codex didn't return a conversation ID") }
        // Naming materializes a new conversation before a second client (the TUI)
        // resumes it, including conversations with no user turn yet.
        if threadID == nil {
            _ = try await connection.request("thread/name/set", params: ["threadId": id, "name": name])
        }
        try Task.checkCancellation()
        register(tabID: tabID, threadID: id)
        if let raw = thread["status"] as? [String: Any], let decoded = CodexStatus.decode(raw) {
            publish(id, decoded)
        }
        Task { await refreshUsage() }
        let command = "codex resume --remote \(Git.quote(endpoint)) --remote-auth-token-env OMUX_CODEX_TOKEN --no-alt-screen \(Git.quote(id))"
        return (id, command)
    }

    func thread(for tabID: UUID) -> String? { threads[tabID] }
    func isConnected(_ tabID: UUID) -> Bool { connections[tabID]?.isReady == true }

    func approval(for tabID: UUID) -> CodexApproval? {
        if let root = threads[tabID], let approval = approvals[root]?.first { return approval }
        return (agents[tabID] ?? []).compactMap { approvals[$0.id]?.first }.first
    }

    /// Answers `approval`, the one the user was shown, and nothing else: once it's answered the
    /// next one moves up, and a second click (a double-click) must not accept that unseen.
    func answer(_ approval: CodexApproval, tabID: UUID, allow: Bool) async throws {
        guard self.approval(for: tabID) == approval, !answering.contains(approval) else { return }
        answering.insert(approval)
        defer { answering.remove(approval) }
        try await connection(for: tabID).respond(to: approval.id, result: ["decision": allow ? "accept" : "decline"])
        // Either client can resolve a request. Do not keep a clickable stale button
        // while waiting for the server's resolved notification.
        removeApproval(approval.id, owner: tabID)
        publish(approval.threadID, CodexStatus(state: turns[approval.threadID] == nil ? .idle : .working))
    }

    func interrupt(_ tabID: UUID) async throws {
        guard let root = threads[tabID] else { return }
        let threadIDs = (agents[tabID] ?? []).map(\.id) + [root]
        for thread in threadIDs {
            guard let turn = turns[thread] else { continue }
            _ = try await connection(for: tabID).request("turn/interrupt", params: ["threadId": thread, "turnId": turn])
            // The response acknowledges cancellation; turn/completed confirms it.
            for _ in 0..<100 {
                if turns[thread] != turn { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard turns[thread] != turn else { throw CodexError.timeout }
        }
    }

    /// Stop a turn before removing its subscriber or deleting its worktree.
    func detach(_ tabID: UUID) async throws {
        guard let thread = threads[tabID] else { return }
        try await interrupt(tabID)
        if let connection = connections.removeValue(forKey: tabID) {
            connection.close()
            try await connection.waitForShutdown()
        }
        threads[tabID] = nil
        approvals[thread] = nil; status[thread] = nil; turns[thread] = nil
    }

    func shutdown() {
        connections.values.forEach { $0.close() }
        connections = [:]
        catalog.close()
    }

    func close(_ tabID: UUID) {
        if let connection = connections.removeValue(forKey: tabID) {
            connection.close()
            retiring[tabID] = Task { try await connection.waitForShutdown() }
        }
        clearActivity(tabID)
        threads[tabID] = nil
    }

    private func clearActivity(_ tabID: UUID) {
        let ids = Set((threads[tabID].map { [$0] } ?? []) + (agents[tabID] ?? []).map(\.id))
        answering = answering.filter { !ids.contains($0.threadID) }
        for id in ids {
            approvals[id] = nil; turns[id] = nil; status[id] = nil; completedTurns[id] = nil; agentOwners[id] = nil
        }
        agents[tabID] = nil
    }

    /// The thread's latest items, oldest first: messages, commands, file changes and tool calls.
    func transcriptItems(threadID: String, tabID: UUID) async throws -> [[String: Any]] {
        guard threads[tabID] == threadID || agentOwners[threadID] == tabID,
              let connection = connections[tabID] else { throw CodexError.disconnected }
        let result = try await connection.request("thread/items/list", params: ["threadId": threadID, "limit": 100, "sortDirection": "desc"])
        let entries = result["data"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["item"] as? [String: Any] }.reversed()
    }

    func transcript(threadID: String, tabID: UUID) async throws -> String {
        let items = try await transcriptItems(threadID: threadID, tabID: tabID)
        return items.compactMap { item -> String? in
            switch item["type"] as? String {
            case "agentMessage": return item["text"] as? String
            case "userMessage":
                let content = item["content"] as? [[String: Any]] ?? []
                return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            case "commandExecution":
                return "```sh\n" + (item["command"] as? String ?? "Command") + "\n```\n" + String((item["aggregatedOutput"] as? String ?? "").prefix(6000))
            case "fileChange": return "File changes · " + (item["status"] as? String ?? "")
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    func recent(limit: Int = 300) async throws -> [CodexConversation] {
        try await catalog.connect()
        var result: [CodexConversation] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": min(100, limit - result.count), "sortKey": "updated_at"]
            if let cursor { params["cursor"] = cursor }
            let page = try await catalog.request("thread/list", params: params)
            let rows = page["data"] as? [[String: Any]] ?? []
            result.append(contentsOf: rows.compactMap(CodexConversation.init))
            let next = page["nextCursor"] as? String
            if next == cursor || rows.isEmpty { break }
            cursor = next
        } while cursor != nil && result.count < limit
        return Array(result.prefix(limit))
    }

    func refreshUsage() async {
        guard !refreshingUsage else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }
        let connection: CodexConnection
        if let ready = connections.values.first(where: \.isReady) {
            connection = ready
        } else {
            // No Codex session yet: ask the catalog server, the one the recent list uses.
            do { try await catalog.connect() } catch {
                quotaBucket = [:]; limits = []; usageError = error.localizedDescription
                return
            }
            connection = catalog
        }
        do {
            // A stale login makes the usage request fail with a 401; say so instead.
            let account = try await connection.request("account/read", params: ["refreshToken": true])
            guard account["account"] is [String: Any] else {
                quotaBucket = [:]; limits = []; usageError = "Codex isn't signed in: run codex login"
                return
            }
            let result = try await connection.request("account/rateLimits/read", params: ["excludeResetCreditDetails": true])
            applyLimits(result, replace: true)
        } catch {
            quotaBucket = [:]; limits = []; usageError = "Codex usage unavailable"
        }
    }

    private func applyLimits(_ result: [String: Any], replace: Bool = false) {
        if replace { quotaBucket = [:] }
        if let bucket = result["rateLimits"] as? [String: Any] {
            if let planType = bucket["planType"] as? String, planType != "unknown" { plan = planType }
            for key in ["primary", "secondary"] {
                if let update = bucket[key] as? [String: Any] {
                    let previous = quotaBucket[key] as? [String: Any] ?? [:]
                    // Sparse: a null field is unknown in this update and doesn't clear what we had.
                    quotaBucket[key] = previous.merging(update.filter { !($0.value is NSNull) }) { _, new in new }
                }
            }
        }
        limits = ["primary", "secondary"].compactMap { key in
            guard let raw = quotaBucket[key] as? [String: Any], let used = raw["usedPercent"] as? Int else { return nil }
            let minutes = raw["windowDurationMins"] as? Int ?? 0
            let label = minutes >= 1440 ? "\(minutes / 1440)d" : minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
            return UsageMonitor.Limit(id: "codex-" + key, label: label, percent: used,
                                      resetsAt: (raw["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        usageError = limits.isEmpty ? "Codex usage unavailable for this account" : nil
    }

    private func publish(_ thread: String, _ value: CodexStatus) {
        status[thread] = value
        let tab = threads.first(where: { $0.value == thread })?.key ?? agentOwners[thread]
        guard let tab, let root = threads[tab] else { return }
        var effective = status[root] ?? CodexStatus(state: .idle)
        if let approval = approval(for: tab) {
            effective = CodexStatus(state: .blocked, kind: "permission", detail: approval.detail)
        }
        onStatus?(tab, effective)
    }

    private func removeApproval(_ id: CodexRequestID, owner: UUID) {
        let owned = Set((threads[owner].map { [$0] } ?? []) + (agents[owner] ?? []).map(\.id))
        for thread in Array(approvals.keys) where owned.contains(thread) {
            approvals[thread]?.removeAll { $0.id == id }
            if approvals[thread]?.isEmpty == true { approvals[thread] = nil }
        }
    }

    func receive(_ message: [String: Any], owner: UUID) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        let thread = params["threadId"] as? String
        if let thread, threads[owner] != thread, agentOwners[thread] != owner { return }
        if let thread, thread == threads[owner], let listener = transcriptListeners[owner] {
            switch method {
            case "item/agentMessage/delta":
                if let item = (params["itemId"] ?? params["item_id"]) as? String, let delta = params["delta"] as? String { listener(.delta(item: item, text: delta)) }
            case "item/started", "item/completed":
                let item = params["item"] as? [String: Any]
                listener(.item(id: item?["id"] as? String ?? "", type: item?["type"] as? String ?? "", completed: method == "item/completed"))
            case "turn/started": listener(.turn(completed: false))
            case "turn/completed": listener(.turn(completed: true))
            default: break
            }
        }
        if let approval = CodexApproval(message: message), completedTurns[approval.threadID] != approval.turnID,
           turns[approval.threadID] == approval.turnID || (turns[approval.threadID] == nil && [.working, .blocked].contains(status[approval.threadID]?.state)) {
            turns[approval.threadID] = approval.turnID
            if approvals[approval.threadID]?.contains(where: { $0.id == approval.id }) != true {
                approvals[approval.threadID, default: []].append(approval)
            }
            publish(approval.threadID, CodexStatus(state: .blocked))
            return
        }
        switch method {
        case "thread/started":
            // A TUI /clear creates a new root conversation. A server is private to
            // this terminal, so the new root can never be attributed to another tab.
            guard let raw = params["thread"] as? [String: Any], let id = raw["id"] as? String else { return }
            if let parent = raw["parentThreadId"] as? String, threads[owner] == parent || agentOwners[parent] == owner {
                updateAgent(id, owner: owner, name: raw["agentNickname"] as? String ?? raw["agentRole"] as? String)
                return
            }
            let source = raw["source"] as? [String: Any]
            guard raw["parentThreadId"] as? String == nil, source?["subAgent"] == nil,
                  let current = threads[owner], current != id else { return }
            clearActivity(owner)
            threads[owner] = id
            onThreadChange?(owner, id)
            guard let connection = connections[owner] else { return }
            Task {
                do {
                    guard threads[owner] == id, connections[owner] === connection else { return }
                    if raw["name"] as? String == nil {
                        _ = try await connection.request("thread/name/set", params: ["threadId": id, "name": "Codex conversation"])
                    }
                    _ = try await connection.request("thread/resume", params: ["threadId": id, "excludeTurns": true])
                } catch { publish(id, CodexStatus(state: .error, detail: error.localizedDescription)) }
            }
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], item["type"] as? String == "collabAgentToolCall" else { return }
            let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
            for id in item["receiverThreadIds"] as? [String] ?? [] {
                updateAgent(id, owner: owner, name: item["prompt"] as? String,
                            state: states[id]?["status"] as? String)
            }
        case "thread/status/changed":
            guard let thread, let raw = params["status"] as? [String: Any], let value = CodexStatus.decode(raw) else { return }
            if value.state == .idle, status[thread]?.state == .done || status[thread]?.state == .error { return }
            publish(thread, value)
            if agentOwners[thread] == owner {
                updateAgent(thread, owner: owner, state: value.state == .working ? "running" : value.state == .error ? "errored" : nil)
            }
        case "turn/started":
            guard let thread, let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
            turns[thread] = id
            approvals[thread] = nil
            publish(thread, CodexStatus(state: .working))
        case "turn/completed":
            guard let thread, let turn = params["turn"] as? [String: Any] else { return }
            guard turn["id"] as? String == turns[thread] else { return }
            turns[thread] = nil; approvals[thread] = nil
            completedTurns[thread] = turn["id"] as? String
            let failed = turn["status"] as? String == "failed"
            let error = turn["error"] as? [String: Any]
            publish(thread, CodexStatus(state: failed ? .error : .done, detail: error?["message"] as? String))
            if agentOwners[thread] == owner { updateAgent(thread, owner: owner, state: failed ? "errored" : "completed") }
        case "serverRequest/resolved":
            guard let id = CodexRequestID(params["requestId"]) else { return }
            removeApproval(id, owner: owner)
            if let thread { publish(thread, CodexStatus(state: turns[thread] == nil ? .idle : .working)) }
        case "account/rateLimits/updated": applyLimits(params)
        default: break
        }
    }

    /// Resume includes the turn that may have started before we subscribed.
    /// Live events received while the request was pending take precedence.
    func synchronizeAgent(_ thread: [String: Any], owner: UUID) {
        guard let id = thread["id"] as? String, agentOwners[id] == owner else { return }
        let history = thread["turns"] as? [[String: Any]] ?? []
        if let active = history.last(where: { $0["status"] as? String == "inProgress" }),
           let turnID = active["id"] as? String {
            guard completedTurns[id] != turnID, turns[id] == nil else { return }
            turns[id] = turnID
        } else if turns[id] != nil || completedTurns[id] != nil {
            return
        }
        if let raw = thread["status"] as? [String: Any], let value = CodexStatus.decode(raw) {
            publish(id, value)
        }
    }

    private func updateAgent(_ id: String, owner: UUID, name: String? = nil, state: String? = nil) {
        guard id != threads[owner] else { return }
        agentOwners[id] = owner
        var list = agents[owner] ?? []
        if let index = list.firstIndex(where: { $0.id == id }) {
            if let name, !name.isEmpty { list[index].name = String(name.prefix(160)) }
            if let state { list[index].state = state }
        } else {
            list.append(CodexAgent(id: id, name: String((name ?? "Codex agent").prefix(160)), state: state ?? "running"))
            status[id] = CodexStatus(state: .working)
            if let connection = connections[owner] {
                Task {
                    // A child can be announced before its initial history write.
                    for attempt in 0..<5 {
                        guard agentOwners[id] == owner, connections[owner] === connection else { return }
                        do {
                            let response = try await connection.request("thread/resume", params: ["threadId": id, "excludeTurns": false])
                            guard agentOwners[id] == owner, connections[owner] === connection else { return }
                            if let thread = response["thread"] as? [String: Any] {
                                synchronizeAgent(thread, owner: owner)
                            }
                            return
                        } catch {
                            do { try await Task.sleep(for: .milliseconds(100 * (attempt + 1))) } catch { return }
                        }
                    }
                }
            }
        }
        agents[owner] = list
    }
}

struct CodexAgent: Identifiable, Equatable {
    let id: String
    var name: String
    var state: String
    var finished: Bool { ["completed", "errored", "shutdown", "interrupted", "notFound"].contains(state) }
}

struct CodexAgentRef: Equatable {
    let tabID: UUID
    let agent: CodexAgent
}

struct CodexConversation: Identifiable, Hashable {
    let id: String
    let cwd: String
    let name: String
    let date: Date

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let cwd = raw["cwd"] as? String else { return nil }
        self.id = id; self.cwd = cwd
        name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (raw["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Codex conversation"
        date = Date(timeIntervalSince1970: (raw["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
    }
}
