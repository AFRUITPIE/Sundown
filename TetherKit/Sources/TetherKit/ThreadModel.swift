import Foundation
import Observation
import TetherProtocol

/// A pending server → client request (approval, question, plan, elicitation, dialog).
public struct PendingRequest: Identifiable, Sendable {
    public let id: String
    public let request: ServerRequest
    let respond: @Sendable (JSONValue?) -> Void
}

/// Client-side reducer for one thread: items in order, turns, status, pending prompts.
@MainActor
@Observable
public final class ThreadModel: Identifiable {
    public let id: String
    public private(set) var info: ThreadInfo?
    public private(set) var summary: ThreadSummary?
    public private(set) var items: [Item] = []
    public private(set) var turns: [Turn] = []
    public private(set) var status: ThreadStatus = .notLoaded
    public private(set) var activity: String?
    public private(set) var pending: [PendingRequest] = []
    public private(set) var lastSeq = 0
    public private(set) var historyLoaded = false
    public private(set) var promptSuggestion: String?
    public private(set) var tasks: [String: TaskEventNotification] = [:]
    public private(set) var authStatus: ThreadAuthStatusNotification?
    public private(set) var apiRetry: ThreadApiRetryNotification?
    public private(set) var lastError: String?
    public var totalCostUsd: Double { turns.compactMap { $0.result?.totalCostUsd }.reduce(0, +) }
    private var index: [String: Int] = [:]

    public init(id: String, summary: ThreadSummary? = nil) {
        self.id = id
        self.summary = summary
        if let s = summary { status = s.status }
    }

    public var title: String {
        if let t = info?.title, !t.isEmpty { return t }
        if let s = summary?.title, !s.isEmpty { return s }
        for case .userMessage(let m) in items where m.synthetic != true {
            for case .text(let t) in m.content { return String(t.text.prefix(80)) }
        }
        return "New thread"
    }

    public var cwd: String? { info?.cwd ?? summary?.cwd }
    public var isRunning: Bool { status == .running || status == .requiresAction }
    public var currentTurn: Turn? { turns.last.flatMap { $0.status == .inProgress ? $0 : nil } }

    // MARK: loading

    func setInfo(_ i: ThreadInfo) {
        info = i
        status = i.status
    }

    func setSummary(_ s: ThreadSummary) {
        summary = s
        if info == nil { status = s.status }
    }

    /// Replace transcript with server history (thread/read or thread/resume includeHistory).
    func loadHistory(items newItems: [Item], turns newTurns: [Turn], seq: Int?) {
        if let seq { lastSeq = seq }
        items = newItems
        turns = newTurns
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        historyLoaded = true
    }

    func setLastSeq(_ s: Int) {
        lastSeq = max(lastSeq, s)
    }

    // MARK: notifications

    func apply(_ n: ServerNotification) {
        if let seq = n.seq {
            if seq <= lastSeq, lastSeq > 0 { return } // already applied (replay overlap)
            lastSeq = seq
        }
        switch n {
        case .threadStarted(let e): setInfo(e.thread)
        case .threadUpdated(let e): info = e.thread
        case .threadStatusChanged(let e):
            status = e.status
            activity = e.activity?.rawValue
            if e.status == .idle { apiRetry = nil }
        case .threadClosed: status = .closed
        case .turnStarted(let e):
            upsertTurn(e.turn)
            promptSuggestion = nil
        case .turnCompleted(let e): upsertTurn(e.turn)
        case .itemStarted(let e): upsert(e.item)
        case .itemUpdated(let e): upsert(e.item)
        case .itemCompleted(let e): upsert(e.item)
        case .itemAgentMessageDelta(let e):
            mutate(e.itemId) { if case .agentMessage(var m) = $0 { m.text += e.delta; $0 = .agentMessage(m) } }
        case .itemReasoningDelta(let e):
            mutate(e.itemId) { if case .reasoning(var m) = $0 { m.text += e.delta; $0 = .reasoning(m) } }
        case .itemToolCallProgress(let e):
            mutate(e.itemId) { if case .toolCall(var t) = $0 { t.elapsedSeconds = e.elapsedSeconds; $0 = .toolCall(t) } }
        case .taskEvent(let e): tasks[e.taskId] = e
        case .threadPromptSuggestion(let e): promptSuggestion = e.suggestion
        case .threadAuthStatus(let e): authStatus = e
        case .threadApiRetry(let e): apiRetry = e
        case .serverRequestResolved(let e):
            // Answered by another client (or cancelled): release our side without replying.
            for p in pending where p.id == e.requestId { p.respond(nil) }
            pending.removeAll { $0.id == e.requestId }
        default: break
        }
    }

    func addPending(_ p: PendingRequest) {
        pending.removeAll { $0.id == p.id }
        pending.append(p)
    }

    /// Answer a prompt. The server broadcasts serverRequest/resolved to every client.
    public func answer(_ p: PendingRequest, with result: JSONValue) {
        pending.removeAll { $0.id == p.id }
        p.respond(result)
    }

    /// Connection dropped: the daemon keeps these parked and re-sends them on resubscribe.
    func clearPending() {
        for p in pending { p.respond(nil) }
        pending.removeAll()
    }

    func setError(_ message: String?) {
        lastError = message
    }

    func dismissAuthStatus() {
        authStatus = nil
    }

    // MARK: helpers

    private func upsertTurn(_ t: Turn) {
        if let i = turns.lastIndex(where: { $0.id == t.id }) { turns[i] = t } else { turns.append(t) }
    }

    private func upsert(_ item: Item) {
        let id = item.id
        if let i = index[id] { items[i] = item } else {
            index[id] = items.count
            items.append(item)
        }
    }

    private func mutate(_ id: String, _ f: (inout Item) -> Void) {
        guard let i = index[id] else { return }
        f(&items[i])
    }

    /// Items belonging to a subagent (Task/Agent tool) — rendered nested in its card.
    public func children(of toolUseId: String) -> [Item] {
        items.filter { $0.parentToolUseId == toolUseId }
    }

    public var topLevelItems: [Item] {
        items.filter { $0.parentToolUseId == nil }
    }
}

extension Item {
    public var id: String {
        switch self {
        case .userMessage(let v): return v.id
        case .agentMessage(let v): return v.id
        case .reasoning(let v): return v.id
        case .toolCall(let v): return v.id
        case .compaction(let v): return v.id
        case .error(let v): return v.id
        case .notice(let v): return v.id
        case .unknown(let v): return v["id"]?.stringValue ?? UUID().uuidString
        }
    }

    public var parentToolUseId: String? {
        switch self {
        case .userMessage(let v): return v.parentToolUseId
        case .agentMessage(let v): return v.parentToolUseId
        case .reasoning(let v): return v.parentToolUseId
        case .toolCall(let v): return v.parentToolUseId
        case .compaction(let v): return v.parentToolUseId
        case .error(let v): return v.parentToolUseId
        case .notice(let v): return v.parentToolUseId
        case .unknown(let v): return v["parentToolUseId"]?.stringValue
        }
    }

    public var turnId: String? {
        switch self {
        case .userMessage(let v): return v.turnId
        case .agentMessage(let v): return v.turnId
        case .reasoning(let v): return v.turnId
        case .toolCall(let v): return v.turnId
        case .compaction(let v): return v.turnId
        case .error(let v): return v.turnId
        case .notice(let v): return v.turnId
        case .unknown(let v): return v["turnId"]?.stringValue
        }
    }
}
