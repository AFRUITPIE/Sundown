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
    /// Whether older items exist before the first one held. The transcript is loaded from its end.
    public private(set) var hasMoreHistory = false
    /// True while an older page is being fetched, so the view asks for one page at a time.
    public internal(set) var loadingOlder = false
    public private(set) var promptSuggestion: String?
    public private(set) var tasks: [String: TaskEventNotification] = [:]
    /// IDs from the SDK's latest level-triggered background-task snapshot.
    public private(set) var backgroundTaskIDs: Set<String> = []
    public private(set) var authStatus: ThreadAuthStatusNotification?
    public private(set) var apiRetry: ThreadApiRetryNotification?
    public private(set) var lastError: String?
    /// Settings chosen while the daemon hasn't loaded the thread, applied when it resumes.
    public private(set) var pendingSettings = PendingSettings()
    public var totalCostUsd: Double { turns.compactMap { $0.result?.totalCostUsd }.reduce(0, +) }
    private var index: [String: Int] = [:]
    /// Bumped by every change to `items`; the derived collections below cache against it.
    public private(set) var itemsVersion = 0
    @ObservationIgnored private var cachedTopLevel: (version: Int, items: [Item])?
    @ObservationIgnored private var cachedRows: (version: Int, rows: [TranscriptRow])?
    @ObservationIgnored private var cachedChildren: (version: Int, byParent: [String: [Item]])?

    public init(id: String, summary: ThreadSummary? = nil) {
        self.id = id
        self.summary = summary
        if let s = summary { status = s.status }
    }

    /// Claude's name for the session once it has one, else the opening prompt.
    public var title: String {
        if let t = summary?.customTitle, !t.isEmpty { return t }
        if let t = info?.title, !t.isEmpty { return t }
        if let s = summary?.title, !s.isEmpty { return s }
        if let p = summary?.firstPrompt, !p.isEmpty { return String(p.prefix(80)) }
        for case .userMessage(let m) in items where m.synthetic != true {
            for case .text(let t) in m.content { return String(t.text.prefix(80)) }
        }
        return "New Chat"
    }

    /// True while the title is only the opening prompt — Claude hasn't named this session yet.
    public var isUnnamed: Bool {
        (summary?.customTitle ?? info?.title ?? summary?.title ?? "").isEmpty
    }

    public var cwd: String? { info?.cwd ?? summary?.cwd }
    public var model: String? { pendingSettings.model ?? info?.model }
    public var effort: EffortLevel? { pendingSettings.effort ?? info?.effort }
    public var permissionMode: PermissionMode? { pendingSettings.permissionMode ?? info?.permissionMode }
    public var fastMode: Bool { pendingSettings.fastMode ?? (info?.fastModeState == "on") }

    /// Watched from its transcript while another client runs it; the daemon hasn't loaded it.
    public var isFollowed: Bool { info?.status == .notLoaded }
    public var isRunning: Bool { status == .running || status == .requiresAction }
    public var currentTurn: Turn? { turns.last.flatMap { $0.status == .inProgress ? $0 : nil } }

    /// True while the model is working with nothing on screen to show for it. Keyed on the last
    /// item: a running tool call has its own spinner, and a reply that has started speaks for itself.
    public var isThinking: Bool {
        guard status == .running else { return false }
        switch items.last {
        case .agentMessage(let m): return m.text.isEmpty
        case .toolCall(let t): return t.status != .running && t.status != .pending
        default: return true
        }
    }

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
    func loadHistory(items newItems: [Item], turns newTurns: [Turn], seq: Int?, hasMore: Bool = false) {
        if let seq { lastSeq = seq }
        items = newItems
        turns = newTurns
        reindex()
        hasMoreHistory = hasMore
        historyLoaded = true
    }

    /// Add an older page to the front.
    func prependHistory(items older: [Item], hasMore: Bool) {
        hasMoreHistory = hasMore
        guard !older.isEmpty else { return }
        let known = Set(items.map(\.id))
        let fresh = older.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        items.insert(contentsOf: fresh, at: 0)
        reindex()
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        itemsVersion &+= 1
    }

    /// Drops the transcript so the next open reads it afresh.
    func unload() {
        items = []
        turns = []
        tasks = [:]
        backgroundTaskIDs = []
        reindex()
        lastSeq = 0
        hasMoreHistory = false
        historyLoaded = false
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
        case .taskBackgroundChanged(let e):
            backgroundTaskIDs = Set((e.tasks.arrayValue ?? []).compactMap { $0["task_id"]?.stringValue })
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

    func editPendingSettings(_ edit: (inout PendingSettings) -> Void) {
        edit(&pendingSettings)
    }

    func takePendingSettings() -> PendingSettings {
        defer { pendingSettings = PendingSettings() }
        return pendingSettings
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
        itemsVersion &+= 1
    }

    private func mutate(_ id: String, _ f: (inout Item) -> Void) {
        guard let i = index[id] else { return }
        f(&items[i])
        itemsVersion &+= 1
    }

    /// Items belonging to a subagent (Task/Agent tool) — rendered nested in its card.
    public func children(of toolUseId: String) -> [Item] {
        if let c = cachedChildren, c.version == itemsVersion { return c.byParent[toolUseId] ?? [] }
        var byParent: [String: [Item]] = [:]
        for item in items {
            guard let parent = item.parentToolUseId else { continue }
            byParent[parent, default: []].append(item)
        }
        cachedChildren = (itemsVersion, byParent)
        return byParent[toolUseId] ?? []
    }

    /// The newest lifecycle event for a subagent tool call (task IDs aren't tool-use IDs).
    public func taskEvent(forToolUseId toolUseId: String) -> TaskEventNotification? {
        tasks.values
            .filter { $0.toolUseId == toolUseId }
            .max { $0.seq < $1.seq }
    }

    /// Background state arrives either as a task event patch or as the SDK's full list.
    public func isTaskBackgrounded(toolUseId: String) -> Bool {
        guard let task = taskEvent(forToolUseId: toolUseId) else { return false }
        return backgroundTaskIDs.contains(task.taskId)
            || task.data["is_backgrounded"]?.boolValue == true
            || task.data["patch"]?["is_backgrounded"]?.boolValue == true
    }

    public var topLevelItems: [Item] {
        if let c = cachedTopLevel, c.version == itemsVersion { return c.items }
        let top = items.filter { $0.parentToolUseId == nil }
        cachedTopLevel = (itemsVersion, top)
        return top
    }

    /// The transcript as it is rendered: top-level items with consecutive finished tool calls
    /// folded into one row.
    public var rows: [TranscriptRow] {
        if let c = cachedRows, c.version == itemsVersion { return c.rows }
        let rows = foldTranscriptRows(topLevelItems)
        cachedRows = (itemsVersion, rows)
        return rows
    }

    /// Position of an item in the transcript, for views that need to know what came after it.
    public func itemIndex(of id: String) -> Int? { index[id] }
}

/// Each field is nil when unchanged; `model` and `effort` can be changed to nil (automatic).
public struct PendingSettings: Sendable, Equatable {
    public var model: String??
    public var effort: EffortLevel??
    public var permissionMode: PermissionMode?
    public var fastMode: Bool?
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

    /// ms since epoch.
    public var createdAt: Double {
        switch self {
        case .userMessage(let v): return v.createdAt
        case .agentMessage(let v): return v.createdAt
        case .reasoning(let v): return v.createdAt
        case .toolCall(let v): return v.createdAt
        case .compaction(let v): return v.createdAt
        case .error(let v): return v.createdAt
        case .notice(let v): return v.createdAt
        case .unknown(let v): return v["createdAt"]?.doubleValue ?? 0
        }
    }
}
