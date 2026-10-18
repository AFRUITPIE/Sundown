import Foundation
import Observation
import TetherProtocol

/// A pending server → client request (approval, question, plan, elicitation, dialog).
public struct PendingRequest: Identifiable, Sendable {
    public let id: String
    public let request: ServerRequest
    let respond: @Sendable (JSONValue?) -> Void

    package init(id: String, request: ServerRequest, respond: @escaping @Sendable (JSONValue?) -> Void) {
        self.id = id
        self.request = request
        self.respond = respond
    }
}

/// One item's current value, observed on its own. A streamed delta changes only its item's box, so
/// only the row showing that item redraws; the transcript and every other row stay as they were.
@MainActor
@Observable
public final class ItemBox: Identifiable {
    public let id: String
    public fileprivate(set) var item: Item

    public init(_ item: Item) {
        id = item.id
        self.item = item
    }
}

/// Client-side reducer for one thread: items in order, turns, status, pending prompts.
@MainActor
@Observable
public final class ThreadModel: Identifiable {
    public let id: String
    public private(set) var info: ThreadInfo?
    public private(set) var summary: ThreadSummary?
    /// The transcript. Reading it observes its structure (an item added, replaced or changing
    /// status), a subagent's items included, not streamed text, which goes to each item's `box(for:)`.
    public var items: [Item] {
        _ = itemsVersion
        _ = childrenVersion
        return storage
    }
    @ObservationIgnored private var storage: [Item] = []
    @ObservationIgnored private var boxes: [String: ItemBox] = [:]
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
    /// Every task of the chat, finished ones included, each as the daemon last said it stands
    /// (`thread/read`'s and `thread/subscribe`'s `tasks`, then `task/updated`), in the order each
    /// was first seen: what the Tasks tab lists. Stored, and changed only by a task's own update, so
    /// a streamed delta never reaches the tab.
    public private(set) var tasks: [TaskState] = []
    @ObservationIgnored private var taskIndex: [String: Int] = [:]
    /// The tasks tool calls started (a subagent, a workflow, a background command), by the call's
    /// id: what the transcript's rows read of them. Assigned only when one of them changes, so a
    /// workflow agent's or a schedule's update doesn't redraw the rows.
    public private(set) var callTasks: [String: TaskState] = [:]
    public private(set) var authStatus: ThreadAuthStatusNotification?
    public private(set) var apiRetry: ThreadApiRetryNotification?
    /// Tasks Claude suggested starting in chats of their own (session tools' suggest_task).
    public private(set) var suggestedTasks: [SuggestedTask] = []
    /// The plan's usage limit as Claude Code last reported it (claude.ai subscriptions).
    public private(set) var rateLimit: RateLimit?
    /// How full the context window was when last asked (0–1), for the toolbar's gauge. Set by
    /// whoever asks (`thread/contextUsage`), after a turn ends or when the breakdown is opened.
    public var contextFill: Double?
    public package(set) var lastError: String?
    /// Settings chosen while the daemon hasn't loaded the thread, applied when it resumes.
    public internal(set) var pendingSettings = PendingSettings()
    private var index: [String: Int] = [:]
    /// Bumped by every structural change to the chat's own items, and by a subagent's edit, which
    /// counts in its turn's edits; the rows cache against it. A streamed delta doesn't bump it (the
    /// rows hold the item's value from before the delta, and render its box), except the first one,
    /// which ends `isThinking`.
    public private(set) var itemsVersion = 0
    /// Bumped when a subagent's item is added or changes: those show only in Tasks, so the
    /// transcript's rows don't fold again for each step a subagent takes.
    public private(set) var childrenVersion = 0
    /// The rows as the current folding draws them, dates and edits included. Only one folding's:
    /// the Tool Calls setting changes rarely, and each kept another copy of the whole transcript.
    @ObservationIgnored private var folded: FoldedRows?
    /// The first index in `storage` changed since `folded` was made: the turns before the last one
    /// are kept unless it's among them.
    @ObservationIgnored private var refoldFrom = 0
    /// Each subagent's items, as their indexes in `storage`.
    @ObservationIgnored private var childIndexes: [String: [Int]] = [:]
    /// A finished workflow agent's transcript, by run and agent id, as `workflow/agentItems` read it.
    /// Let go when the chat is.
    @ObservationIgnored private var workflowAgentItems: [String: [Item]] = [:]
    /// When items started live, as opposed to arriving with history, for the rows that fade in.
    /// Unobserved: a row reads it once, when it appears.
    @ObservationIgnored private var started: [String: ContinuousClock.Instant] = [:]
    /// The opening prompt's first words, kept when the items that hold it are let go (`trim`), so
    /// an unnamed chat's title doesn't turn into a later prompt.
    @ObservationIgnored private var openingPrompt: String?

    /// Claude's name for the session once it has one, else the opening prompt. Stored rather than
    /// computed: a title that reads `items` would make every streamed delta invalidate the sidebar
    /// row and the window title.
    public private(set) var title = "New Chat"

    /// How the last turn ended, for the sidebar's dot. Stored and kept when the transcript is let
    /// go, so the sidebar never reads `turns`. Nil for a chat not loaded this launch.
    public private(set) var lastTurnStatus: TurnStatus?
    /// A finished reply no window has shown yet: set when a turn completes in a chat nobody is
    /// looking at, cleared when a window shows it. This launch only.
    public private(set) var hasUnseenReply = false

    /// The top-level reply being streamed into right now, if any: from its first live text until it
    /// completes, or its turn ends. Only this reply's text fades in as it arrives. Stored, and
    /// changed at most a couple of times per reply, so the rows that compare against it redraw
    /// then and not per delta.
    public private(set) var streamingReplyID: String?

    /// The latest top-level prompt to arrive live, as the host echoes it: never one that came with
    /// history. The transcript eases in the room it takes. Stored, and changed once a prompt.
    public private(set) var arrivedPrompt: String?
    /// A New Chat window's stand-in for a chat it's starting (`PendingStart.placeholder`), before
    /// the host has answered: the transcript says Starting session.
    public private(set) var isStarting = false

    public init(id: String, summary: ThreadSummary? = nil) {
        self.id = id
        self.summary = summary
        if let s = summary { status = s.status }
        refreshTitle()
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

    /// The session tag Archive sets.
    public static let archivedTag = "archived"
    public var isArchived: Bool { summary?.tag == Self.archivedTag }
    public var isRunning: Bool { status == .running || status == .requiresAction }

    /// Background commands and agents still running, though the turn that started them may have
    /// ended, as the daemon counts them (`thread/status/changed`, `thread/list`). Stored, so the
    /// sidebar reads it without reading the transcript.
    public private(set) var backgroundTaskCount = 0
    /// Claude is still at work in the background: a chat sitting idle while its agents run.
    public var hasBackgroundWork: Bool { backgroundTaskCount > 0 }
    public var currentTurn: Turn? { turns.last.flatMap { $0.status == .inProgress ? $0 : nil } }

    /// The latest turn that has ended, as its id and outcome. Changes when a turn ends (or history
    /// brings one), not when the next one starts: what is asked again after a turn, such as the
    /// working tree or the context window, is keyed on it.
    public var lastFinishedTurn: String? {
        turns.last { $0.status != .inProgress }.map { "\($0.id):\($0.status.rawValue)" }
    }

    /// True while the model is working with nothing on screen to show for it. Keyed on the last
    /// item: a running tool call has its own spinner, and a reply that has started speaks for itself.
    public var isThinking: Bool {
        guard status == .running else { return false }
        // Top-level items only: a running subagent's own calls and messages arrive many times a
        // second while its Agent call is what the chat shows, and each one added and removed the
        // line, moving the whole transcript. A reply that has started speaks for itself, empty or
        // not: its first words come a frame after it, and showing the line for that frame bumped
        // the transcript at every reply.
        switch items.last(where: { $0.parentToolUseId == nil }) {
        case .agentMessage: return false
        case .toolCall(let t): return t.status != .running && t.status != .pending
        default: return true
        }
    }

    // MARK: loading

    // Assigned only when they differ: an observed property tells its views even when it's given the
    // same value, and every chat's summary comes again after each turn.

    package func setInfo(_ i: ThreadInfo) {
        if info != i { info = i }
        if status != i.status { status = i.status }
        refreshTitle()
    }

    package func setSummary(_ s: ThreadSummary) {
        if summary != s { summary = s }
        if info == nil, status != s.status { status = s.status }
        // Counted only for a chat the daemon runs: one it hasn't loaded runs nothing.
        let count = s.backgroundTasks ?? 0
        if count != backgroundTaskCount { backgroundTaskCount = count }
        refreshTitle()
    }

    private func refreshTitle() {
        let next = derivedTitle()
        if next != title { title = next }
    }

    private func derivedTitle() -> String {
        if let t = summary?.customTitle, !t.isEmpty { return t }
        if let t = info?.title, !t.isEmpty { return t }
        if let s = summary?.title, !s.isEmpty { return s }
        if let p = summary?.firstPrompt, !p.isEmpty { return String(p.prefix(80)) }
        return openingPrompt ?? Self.firstPrompt(in: storage) ?? "New Chat"
    }

    private static func firstPrompt(in items: [Item]) -> String? {
        for case .userMessage(let m) in items where m.synthetic != true {
            if let t = m.texts.first { return String(t.prefix(80)) }
        }
        return nil
    }

    /// Sets up a stand-in for a chat being started (`PendingStart`): its settings as they were asked
    /// for, and the prompt as it was sent, arriving as a prompt sent from the window does. Never one
    /// of the host's chats, so nothing here is history: no sequence number, no subscription.
    func beginStarting(info: ThreadInfo, prompt: Item) {
        setInfo(info)
        loadHistory(items: [], turns: [], seq: nil)
        isStarting = true
        noteStarted(prompt.id)
        if case .userMessage = prompt { arrivedPrompt = prompt.id }
        upsert(prompt)
    }

    /// The host has answered for the chat this stands in for.
    func endStarting() {
        if isStarting { isStarting = false }
    }

    /// Replace transcript with server history (thread/read or thread/resume includeHistory), and
    /// the tasks with the ones it came with, which are as of `seq`.
    package func loadHistory(items newItems: [Item], turns newTurns: [Turn], seq: Int?, hasMore: Bool = false,
                     tasks newTasks: [TaskState]? = nil) {
        reshaped(historyLoaded ? "reloaded \(newItems.count) items over \(storage.count)" : "loaded \(newItems.count) items")
        if let seq { lastSeq = seq }
        if let newTasks { setTasks(newTasks) }
        storage = newItems
        if turns != newTurns { turns = newTurns }
        noteLastTurn()
        reindex()
        if hasMoreHistory != hasMore { hasMoreHistory = hasMore }
        if !historyLoaded { historyLoaded = true }
    }

    /// The last time the items were replaced, cut or added to above, and how: what the transcript
    /// logs if it finds itself showing no rows.
    @ObservationIgnored public private(set) var lastReshape: (what: String, at: Date)?

    private func reshaped(_ what: String) { lastReshape = (what, Date()) }

    /// Add an older page to the front.
    func prependHistory(items older: [Item], hasMore: Bool) {
        if hasMoreHistory != hasMore { hasMoreHistory = hasMore }
        let fresh = older.filter { index[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        reshaped("an older page of \(fresh.count) items")
        storage.insert(contentsOf: fresh, at: 0)
        reindex()
    }

    /// Every bulk replacement of `items` goes through here, so the fallback title is refreshed
    /// once per history load rather than once per streamed delta.
    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: storage.enumerated().map { ($1.id, $0) })
        // One box per item, made here rather than when a row first asks. Boxes outlive a reload: a
        // row already showing an item keeps observing the same one.
        var next: [String: ItemBox] = [:]
        next.reserveCapacity(storage.count)
        for item in storage {
            if let box = boxes[item.id] {
                if box.item != item { box.item = item }
                next[item.id] = box
            } else {
                next[item.id] = ItemBox(item)
            }
        }
        boxes = next
        childIndexes = [:]
        for (i, item) in storage.enumerated() {
            if let parent = item.parentToolUseId { childIndexes[parent, default: []].append(i) }
        }
        // Every index may have moved: all the rows fold again.
        refoldFrom = 0
        itemsVersion &+= 1
        childrenVersion &+= 1
        if let id = streamingReplyID, index[id] == nil { setStreamingReply(nil) }
        refreshTitle()
    }

    /// Drops the transcript so the next open reads it afresh.
    func unload() {
        reshaped("unloaded")
        started = [:]
        openingPrompt = nil
        storage = []
        datedPrompts = []
        turns = []
        setTasks([])
        workflowAgentItems = [:]
        reindex()
        folded = nil
        lastSeq = 0
        hasMoreHistory = false
        historyLoaded = false
    }

    /// Keeps only the last `count` items of a chat no window shows, and nothing worked out from
    /// them. Its place in the stream stays as it is — `lastSeq`, the turns, the tasks —
    /// so live events go on applying after it with no gap or overlap, and the items let go load
    /// again a page at a time when it's shown and scrolled back (`hasMoreHistory`).
    func trim(toLast count: Int) {
        // What's worked out from the items is made again when it's next asked for.
        defer { folded = nil }
        guard historyLoaded, storage.count > count else { return }
        reshaped("trimmed \(storage.count) items to \(count)")
        // Its title stays the prompt it opened with, until Claude names it.
        if openingPrompt == nil { openingPrompt = Self.firstPrompt(in: storage) }
        storage.removeFirst(storage.count - count)
        started = [:]
        let held = Set(storage.map(\.id))
        reindex()
        // An agent's transcript is kept only while its workflow's call is.
        let runs = Set(callTasks.values.lazy.filter { held.contains($0.id) }.compactMap(\.workflow?.runId))
        workflowAgentItems = workflowAgentItems.filter { key, _ in
            key.split(separator: "/", maxSplits: 1).first.map { runs.contains(String($0)) } ?? false
        }
        if !hasMoreHistory { hasMoreHistory = true }
    }

    // MARK: notifications

    /// Returns false for a notification already applied (a replay overlap, or a stale stream's).
    @discardableResult
    package func apply(_ n: ServerNotification) -> Bool {
        if let seq = n.seq {
            if seq <= lastSeq, lastSeq > 0 { return false }
            lastSeq = seq
        }
        switch n {
        case .threadStarted(let e): setInfo(e.thread)
        case .threadUpdated(let e):
            if info != e.thread { info = e.thread }
            refreshTitle()
        case .threadStatusChanged(let e):
            // The sidebar reads the status: only a change of it redraws the rows.
            if status != e.status { status = e.status }
            if activity != e.activity?.rawValue { activity = e.activity?.rawValue }
            if let count = e.backgroundTasks, count != backgroundTaskCount { backgroundTaskCount = count }
            if e.status == .idle, apiRetry != nil { apiRetry = nil }
        case .threadClosed:
            status = .closed
            // Its background tasks ended with its process, which the daemon says of each.
            if backgroundTaskCount != 0 { backgroundTaskCount = 0 }
            setStreamingReply(nil)
        case .turnStarted(let e):
            Signposts.replyStarted(in: self)
            upsertTurn(e.turn)
            promptSuggestion = nil
        case .turnCompleted(let e):
            Signposts.replyEnded(in: self)
            upsertTurn(e.turn)
            setStreamingReply(nil)
        case .turnUpdated(let e):
            upsertTurn(e.turn)
        case .itemStarted(let e):
            if index[e.item.id] == nil {
                noteStarted(e.item.id)
                if case .userMessage(let m) = e.item, m.parentToolUseId == nil { arrivedPrompt = m.id }
            }
            upsert(e.item)
            if case .agentMessage(let m) = e.item, m.parentToolUseId == nil { setStreamingReply(m.id) }
        case .itemUpdated(let e): upsert(e.item)
        case .itemCompleted(let e):
            upsert(e.item)
            if e.item.id == streamingReplyID { setStreamingReply(nil) }
        case .itemAgentMessageDelta(let e):
            // A reply that started before this client was watching streams too.
            if e.itemId != streamingReplyID, let i = index[e.itemId],
               case .agentMessage(let m) = storage[i], m.parentToolUseId == nil {
                setStreamingReply(e.itemId)
            }
            appendReplyText(e.delta, to: e.itemId)
        case .itemReasoningDelta(let e):
            mutate(e.itemId) { if case .reasoning(var m) = $0 { m.text += e.delta; $0 = .reasoning(m) } }
        case .itemToolCallProgress(let e):
            mutate(e.itemId) { if case .toolCall(var t) = $0 { t.elapsedSeconds = e.elapsedSeconds; $0 = .toolCall(t) } }
        case .taskUpdated(let e): updateTask(e.task)
        case .threadPromptSuggestion(let e): promptSuggestion = e.suggestion
        case .threadAuthStatus(let e): authStatus = e
        case .threadApiRetry(let e): apiRetry = e
        case .threadRateLimit(let e): rateLimit = RateLimit(e.info)
        case .threadTaskSuggested(let e):
            suggestedTasks.append(SuggestedTask(title: e.title, prompt: e.prompt, cwd: e.cwd))
        case .serverRequestResolved(let e):
            // Answered by another client (or cancelled): release our side without replying.
            for p in pending where p.id == e.requestId { p.respond(nil) }
            pending.removeAll { $0.id == e.requestId }
        default: break
        }
        return true
    }

    package func addPending(_ p: PendingRequest) {
        pending.removeAll { $0.id == p.id }
        pending.append(p)
    }

    /// A suggested task started or dismissed.
    public func dismissSuggestedTask(_ id: UUID) {
        suggestedTasks.removeAll { $0.id == id }
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

    func takePendingSettings() -> PendingSettings {
        defer { pendingSettings = PendingSettings() }
        return pendingSettings
    }

    // MARK: helpers

    /// The tool call with this id, as it is now. Not observed: what the Tasks tab reads from it (who
    /// started it, when) doesn't change after it's added.
    public func call(_ toolUseId: String) -> Item.ToolCall? {
        guard let i = index[toolUseId], case .toolCall(let call) = storage[i] else { return nil }
        return call
    }

    /// Whether a tool call is the chat's own rather than a subagent's.
    public func isTopLevelCall(_ toolUseId: String) -> Bool {
        guard let i = index[toolUseId] else { return false }
        return storage[i].parentToolUseId == nil
    }

    private func noteLastTurn() {
        if let status = turns.last?.status, status != lastTurnStatus { lastTurnStatus = status }
    }

    /// A turn finished where no window shows the chat.
    func noteUnseenReply() { if !hasUnseenReply { hasUnseenReply = true } }

    /// A window shows the chat.
    func noteSeen() { if hasUnseenReply { hasUnseenReply = false } }

    private func upsertTurn(_ t: Turn) {
        let held = turns.lastIndex(where: { $0.id == t.id })
        let edits = held.map { turns[$0].edits } ?? nil
        if let i = held { turns[i] = t } else { turns.append(t) }
        noteLastTurn()
        // Its edits' totals are drawn after it (at its end, or when a background agent edits a
        // file later): its rows fold again from its prompt.
        if edits != t.edits, let prompt = storage.lastIndex(where: { $0.isPrompt && $0.turnId == t.id }) {
            refoldFrom = min(refoldFrom, prompt)
            itemsVersion &+= 1
        }
    }

    private func upsert(_ item: Item) {
        let id = item.id
        let i: Int
        let previous: Item?
        if let held = index[id] {
            i = held
            previous = storage[i]
            storage[i] = item
        } else {
            // An item from before the first one held, finishing now (a background task's call):
            // the page it's on brings it when that loads. Put at the end it would read as new.
            if hasMoreHistory, item.createdAt > 0, let first = storage.first?.createdAt, item.createdAt < first { return }
            i = storage.count
            previous = nil
            index[id] = i
            storage.append(item)
        }
        if let box = boxes[id] { box.item = item } else { boxes[id] = ItemBox(item) }
        if let previous, previous.parentToolUseId != item.parentToolUseId {
            reindex() // an item moved between a subagent and the chat, which never happens in practice
        } else {
            noteChange(of: item, at: i, isNew: previous == nil, was: previous)
        }
        // Only an opening user message can move the title, and only until Claude names the session.
        if isUnnamed, case .userMessage(let m) = item, m.synthetic != true { refreshTitle() }
    }

    /// What an item added or replaced changes: the rows, when it's the chat's own
    /// or an edit (a subagent's edits count in its turn's); its subagent's children, when it's a
    /// subagent's.
    private func noteChange(of item: Item, at i: Int, isNew: Bool, was previous: Item?) {
        if let parent = item.parentToolUseId {
            if isNew { childIndexes[parent, default: []].append(i) }
            childrenVersion &+= 1
        }
        if item.parentToolUseId == nil || item.isEditCall || previous?.isEditCall == true {
            refoldFrom = min(refoldFrom, i)
            itemsVersion &+= 1
        }
    }

    private func noteStarted(_ id: String) {
        let now = ContinuousClock.now
        // Only the last moment matters, so the record stays small in a long turn.
        if started.count > 64 { started = started.filter { now - $0.value < .seconds(2) } }
        started[id] = now
    }

    #if DEBUG
    /// For a `#Preview`'s still: nothing in it is arriving, so no row is caught mid-fade.
    package func settleArrivals() { started = [:] }
    #endif

    /// Whether the item started live within the last moment, so its row fades in as it appears.
    /// False for one that came with history, or a row made again when scrolled back to.
    public func justStarted(_ id: String) -> Bool {
        started[id].map { ContinuousClock.now - $0 < .milliseconds(500) } ?? false
    }

    /// A streamed change to one item: its box, not the transcript's structure.
    private func mutate(_ id: String, _ f: (inout Item) -> Void) {
        guard let i = index[id] else { return }
        let wasEmpty = storage[i].isEmptyMessage
        f(&storage[i])
        boxes[id]?.item = storage[i]
        if wasEmpty != storage[i].isEmptyMessage { itemsVersion &+= 1 }
    }

    /// A reply's streamed text, appended where it is. The transcript and the item's box each keep
    /// their own copy, so neither is shared when the next delta comes. Rebuilt from a copy, as
    /// `mutate` does, the whole reply was copied for every delta: a reply cost the square of its
    /// length to stream.
    private func appendReplyText(_ delta: String, to id: String) {
        guard !delta.isEmpty, let i = index[id], case .agentMessage = storage[i] else { return }
        let wasEmpty = storage[i].isEmptyMessage
        storage[i].appendReplyText(delta)
        boxes[id]?.item.appendReplyText(delta)
        if wasEmpty { itemsVersion &+= 1 }
    }

    private func setStreamingReply(_ id: String?) {
        if streamingReplyID != id { streamingReplyID = id }
    }

    /// The last item the transcript draws: a top-level one that isn't reasoning, which is kept
    /// but never shown, nor a task's outcome, which Tasks shows. What the live run of calls and
    /// the Thinking line go by.
    public var lastShownItem: Item? {
        items.last { item in
            if case .reasoning = item { return false }
            return item.parentToolUseId == nil && !item.isTaskOutcome
        }
    }

    /// Claude's messages in the turn that ends with `id`, in order: what the turn's Copy copies.
    public func turnReplies(through id: String) -> [String] {
        guard var i = index[id] else { return [] }
        var texts: [String] = []
        while i >= 0 {
            switch storage[i] {
            case .userMessage(let m) where m.parentToolUseId == nil && ((m.synthetic != true && m.origin == nil) || m.origin == "wakeup"):
                return texts.reversed()
            case .agentMessage(let m) where m.parentToolUseId == nil && !m.text.isEmpty:
                texts.append(m.text)
            default: break
            }
            i -= 1
        }
        return texts.reversed()
    }

    /// The item's box, for a row that renders it. Every held item has one; an item from elsewhere
    /// (a preview) gets a box of its own that the thread doesn't keep.
    public func box(for item: Item) -> ItemBox {
        boxes[item.id] ?? ItemBox(item)
    }

    /// Items belonging to a subagent (Task/Agent tool) — shown in Tasks. Observes the
    /// subagents' items, not the transcript's.
    public func children(of toolUseId: String) -> [Item] {
        _ = childrenVersion
        return childIndexes[toolUseId]?.map { storage[$0] } ?? []
    }

    // MARK: tasks

    /// The tasks as the daemon says they stand now, whole.
    package func setTasks(_ list: [TaskState]) {
        var next: [TaskState] = []
        var index: [String: Int] = [:]
        next.reserveCapacity(list.count)
        for task in list {
            if let i = index[task.id] { next[i] = task } else { index[task.id] = next.count; next.append(task) }
        }
        taskIndex = index
        if next != tasks { tasks = next }
        refreshCallTasks()
    }

    /// One task's state, replacing what was said of it before.
    private func updateTask(_ task: TaskState) {
        if let i = taskIndex[task.id] {
            guard tasks[i] != task else { return }
            tasks[i] = task
        } else {
            taskIndex[task.id] = tasks.count
            tasks.append(task)
        }
        if task.isCallTask, let call = task.toolUseId, callTasks[call] != task { callTasks[call] = task }
    }

    private func refreshCallTasks() {
        var next: [String: TaskState] = [:]
        for task in tasks where task.isCallTask { next[task.toolUseId!] = task }
        if next != callTasks { callTasks = next }
    }

    /// The names the daemon gives the chat's workflows, by their calls' ids, for Find.
    public var workflowNames: [String: String] {
        callTasks.compactMapValues { $0.kind == .workflow ? $0.workflow?.name : nil }
    }

    /// A finished workflow agent's transcript, if it has been read.
    public func workflowAgentTranscript(runId: String, agentId: String) -> [Item]? {
        workflowAgentItems["\(runId)/\(agentId)"]
    }

    package func rememberWorkflowAgentTranscript(_ items: [Item], runId: String, agentId: String) {
        workflowAgentItems["\(runId)/\(agentId)"] = items
    }

    /// The chat's own items, without its subagents'. For previews and tests; the transcript draws
    /// `rows(_:)`.
    public var topLevelItems: [Item] {
        _ = itemsVersion
        return storage.filter { $0.parentToolUseId == nil }
    }

    /// The transcript as it is drawn: the rows folded as View ▸ Tool Calls says, with
    /// the date above a prompt after a break and the files each finished turn edited after it. The
    /// edits, and Worked For's folding, depend on whether the last turn is still running.
    ///
    /// The same as folding every item at once, made in two parts: the turns before the last one,
    /// kept until one of their items changes (a turn that finishes joins them), and the last turn,
    /// which folds again each time its items do.
    public func rows(_ folding: TranscriptFolding) -> [TranscriptRow] {
        foldedRows(folding).rows
    }

    /// The reader's own prompts among `rows(folding)`, for VoiceOver's Prompts rotor. Made with the
    /// rows, so drawing the transcript doesn't go through all of them again.
    public func prompts(_ folding: TranscriptFolding) -> [TranscriptPrompt] {
        foldedRows(folding).prompts
    }

    /// The rows as one folding draws them, and where the last turn's begin.
    private struct FoldedRows {
        let folding: TranscriptFolding
        /// Where the last turn starts in `storage` (at its prompt), and its rows and prompts among
        /// `rows` and `prompts`.
        var lastTurn = 0, lastTurnRows = 0, lastTurnPrompts = 0
        /// What the date separators carry into the last turn.
        var dates = DateSeparators.Carry()
        var version = 0
        var running = false
        var rows: [TranscriptRow] = []
        var prompts: [TranscriptPrompt] = []
    }

    private func foldedRows(_ folding: TranscriptFolding) -> FoldedRows {
        let running = isRunning
        if let f = folded, f.folding == folding, f.version == itemsVersion, f.running == running { return f }
        // What's before the last turn is kept unless something in it changed, edited in place rather
        // than copied; the last turn always folds again.
        var f = folded.flatMap { $0.folding == folding && refoldFrom >= $0.lastTurn ? $0 : nil } ?? FoldedRows(folding: folding)
        folded = nil
        f.rows.removeSubrange(f.lastTurnRows...)
        f.prompts.removeSubrange(f.lastTurnPrompts...)
        let totals = Dictionary(turns.compactMap { t in t.edits.map { (t.id, $0) } }, uniquingKeysWith: { _, b in b })
        func fold(_ items: Range<Int>, running: Bool, dates: inout DateSeparators.Carry) -> [TranscriptRow] {
            transcriptRows(storage[items], folding: folding, running: running, dates: &dates, dated: &datedPrompts, totals: totals)
        }
        // The turns finished since go with those kept.
        let lastTurn = storage.lastIndex(where: \.isPrompt) ?? 0
        if f.lastTurn < lastTurn {
            let rows = fold(f.lastTurn..<lastTurn, running: false, dates: &f.dates)
            f.rows += rows
            f.prompts += TranscriptPrompt.list(in: rows)
            (f.lastTurn, f.lastTurnRows, f.lastTurnPrompts) = (lastTurn, f.rows.count, f.prompts.count)
        }
        var dates = f.dates
        let rows = fold(lastTurn..<storage.count, running: running, dates: &dates)
        f.rows += rows
        f.prompts += TranscriptPrompt.list(in: rows)
        f.version = itemsVersion
        f.running = running
        refoldFrom = .max
        folded = f
        return f
    }

    /// The prompts that have had a date above them since the chat was loaded. The first prompt held
    /// gets one because nothing is known before it; an older page going in above can make it a
    /// prompt with no break before it, and taking its date away then moved every row under it while
    /// the reader was looking at the top. So once a prompt has had its date, it keeps it.
    @ObservationIgnored private var datedPrompts: Set<String> = []

    /// The foldings whose rows are held, for tests: the current one's alone.
    var foldingsHeld: [TranscriptFolding] { folded.map { [$0.folding] } ?? [] }

    /// How many items, or things made from them, the thread holds on to, for tests: the transcript,
    /// its boxes, and what's worked out from it.
    var itemsHeld: Int {
        storage.count + boxes.count
            + (folded?.rows.count ?? 0) + childIndexes.values.reduce(0) { $0 + $1.count }
            + started.count
    }

    /// Position of an item in the transcript, for views that need to know what came after it.
    public func itemIndex(of id: String) -> Int? { index[id] }
}

extension Item {
    var isWorkflowCall: Bool {
        if case .toolCall(let call) = self { return call.isWorkflow }
        return false
    }

    /// A prompt of the chat's own, where a turn starts.
    var isPrompt: Bool {
        if case .userMessage(let m) = self { return m.parentToolUseId == nil }
        return false
    }
}

private extension TaskState {
    /// A task a tool call started and its row says how it stands: not a workflow's agent, which has
    /// no call, nor a schedule or a goal.
    var isCallTask: Bool {
        toolUseId != nil && kind != .workflowAgent && kind != .schedule && kind != .goal
    }
}

private extension Item {
    /// A call that edits files, finished or not: its changes count in its turn's edits.
    var isEditCall: Bool {
        guard case .toolCall(let call) = self else { return false }
        return call.kind == .fileEdit || call.kind == .fileWrite || call.kind == .notebookEdit
    }

    /// An agent message with no text yet; its first delta ends `isThinking`.
    var isEmptyMessage: Bool {
        if case .agentMessage(let m) = self { return m.text.isEmpty }
        return false
    }
}

private extension Item {
    /// Appends to a reply's text in place: taken out of `self` first, the text isn't also held by
    /// `self` while it grows, so it isn't copied whole.
    mutating func appendReplyText(_ delta: String) {
        guard case .agentMessage(var message) = self else { return }
        self = .unknown(.null)
        message.text += delta
        self = .agentMessage(message)
    }
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

    /// The turn it's part of.
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

/// A claude.ai plan's usage limit: how much of it is used, whether requests still go through, and
/// when it resets.
public struct RateLimit: Sendable, Equatable {
    public enum Status: String, Sendable { case allowed, warning = "allowed_warning", rejected }
    public let status: Status
    /// 0 to 1.
    public let utilization: Double?
    public let resetsAt: Date?
    /// "five_hour", "seven_day", …
    public let kind: String?

    public init(_ info: JSONValue) {
        status = info["status"]?.stringValue.flatMap(Status.init(rawValue:)) ?? .allowed
        let used = info["utilization"]?.doubleValue
        // A fraction, from the API's rate-limit headers, and a little over 1 past the limit. Only a
        // CLI that reported a percentage gives more than 2; anything up to that is a fraction, or
        // 1% read as a percentage would be a full limit, and 105% as a fraction would be 1%.
        utilization = used.map { $0 > 2 ? $0 / 100 : $0 }
        resetsAt = info["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
        kind = info["rateLimitType"]?.stringValue
    }

    /// "5-hour limit", as a sentence names it.
    public var name: String {
        switch kind {
        case "five_hour": "5-hour limit"
        case "seven_day": "weekly limit"
        case "seven_day_opus": "weekly Opus limit"
        case "seven_day_sonnet": "weekly Sonnet limit"
        case "overage", "seven_day_overage_included": "extra usage limit"
        default: "usage limit"
        }
    }

    /// Whether what it says still holds at `now`: a limit that has reset says nothing any more.
    /// What the status strip says about the limit at `now`: nothing while requests go through as
    /// usual or once it has reset; otherwise how much is used, or that it's reached, and when it
    /// resets.
    public func warning(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard status != .allowed, resetsAt.map({ $0 > now }) ?? true else { return nil }
        let reset = resetsAt.map { " It resets \(Self.describeReset($0, now: now, calendar: calendar, locale: locale))." } ?? ""
        switch status {
        case .rejected:
            return "You’ve reached your \(name).\(reset)"
        default:
            let used = utilization.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))% of " } ?? "most of "
            return "You’ve used \(used)your \(name).\(reset)"
        }
    }

    /// When a limit resets, as the rest of a sentence: "at 3:00 PM" today, "tomorrow at 3:00 PM",
    /// "on Tuesday at 3:00 PM" within the week, and "on Oct 5 at 3:00 PM" after that. A weekly
    /// limit's time of day alone didn't say which day.
    static func describeReset(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                    calendar: calendar, timeZone: calendar.timeZone))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch days {
        case ...0: return "at \(clock)"
        case 1: return "tomorrow at \(clock)"
        case 2..<7: return "on \(date.formatted(day.weekday(.wide))) at \(clock)"
        default: return "on \(date.formatted(day.month(.abbreviated).day())) at \(clock)"
        }
    }
}

/// A task Claude suggested starting separately: a title, the prompt for it, and where.
public struct SuggestedTask: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let title: String
    public let prompt: String
    public let cwd: String?
}
