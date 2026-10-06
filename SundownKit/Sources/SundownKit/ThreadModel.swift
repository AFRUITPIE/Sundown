import Foundation
import Observation
import TetherProtocol

/// A pending server → client request (approval, question, plan, elicitation, dialog).
public struct PendingRequest: Identifiable, Sendable {
    public let id: String
    public let request: ServerRequest
    let respond: @Sendable (JSONValue?) -> Void
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
    public private(set) var tasks: [String: TaskEventNotification] = [:]
    /// IDs from the SDK's latest level-triggered background-task snapshot.
    public private(set) var backgroundTaskIDs: Set<String> = []
    public private(set) var authStatus: ThreadAuthStatusNotification?
    public private(set) var apiRetry: ThreadApiRetryNotification?
    /// Tasks Claude suggested starting in chats of their own (session tools' suggest_task).
    public private(set) var suggestedTasks: [SuggestedTask] = []
    /// The plan's usage limit as Claude Code last reported it (claude.ai subscriptions).
    public private(set) var rateLimit: RateLimit?
    /// How full the context window was when last asked (0–1), for the toolbar's gauge. Set by
    /// whoever asks (`thread/contextUsage`), after a turn ends or when the breakdown is opened.
    public var contextFill: Double?
    public private(set) var lastError: String?
    /// Settings chosen while the daemon hasn't loaded the thread, applied when it resumes.
    public private(set) var pendingSettings = PendingSettings()
    public var totalCostUsd: Double { turns.compactMap { $0.result?.totalCostUsd }.reduce(0, +) }
    private var index: [String: Int] = [:]
    /// Bumped by every structural change to the chat's own items, and by a subagent's edit, which
    /// counts in its turn's edits; the rows cache against it. A streamed delta doesn't bump it (the
    /// rows hold the item's value from before the delta, and render its box), except the first one,
    /// which ends `isThinking`.
    public private(set) var itemsVersion = 0
    /// Bumped when a subagent's item is added or changes: those show only in its card, so the
    /// transcript's rows don't fold again for each step a subagent takes.
    public private(set) var childrenVersion = 0
    @ObservationIgnored private var cachedTopLevel: (version: Int, items: [Item])?
    @ObservationIgnored private var cachedRows: (version: Int, rows: [TranscriptRow])?
    /// The rows as the current folding draws them, dates and edits included. Only one folding's:
    /// the Tool Calls setting changes rarely, and each kept another copy of the whole transcript.
    @ObservationIgnored private var folded: FoldedRows?
    /// The first index in `storage` changed since `folded` was made. The turns before it are kept
    /// as they are; the rest fold again.
    @ObservationIgnored private var refoldFrom = 0
    /// Each finished edit call's changes, by call id: counting a change diffs its old and new text,
    /// and a finished call's input never changes, so the earlier turns aren't diffed again every
    /// time the running one adds an item. Worked out off the main actor as calls finish and pages
    /// arrive (`remember(_:)`), so drawing the rows only looks them up.
    @ObservationIgnored private(set) var fileChanges: [String: [FileChange]] = [:]
    /// How many calls' changes the rows had to work out on the main actor, for tests: none, once
    /// the pages and finished calls have been counted off it.
    @ObservationIgnored private(set) var changesCountedOnMainActor = 0
    /// Each subagent's items, as their indexes in `storage`.
    @ObservationIgnored private var childIndexes: [String: [Int]] = [:]
    /// The subagent calls, the chat's own and its subagents', in transcript order, for the Tasks list.
    @ObservationIgnored private var subagentCallIDs: [String] = []
    /// The task each tool call started, by tool-use id: the one with the latest event.
    @ObservationIgnored private var taskIDsByToolUse: [String: String] = [:]
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
    /// A turn is starting here and nothing of it has arrived yet: the running status and the turn
    /// come just before the prompt's echo. Until then, the transcript lays out as it did before.
    public private(set) var awaitingPrompt = false
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
    /// sidebar reads it without reading the transcript; 0 from a server too old to say.
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
        switch items.last {
        case .agentMessage(let m): return m.text.isEmpty
        case .toolCall(let t): return t.status != .running && t.status != .pending
        default: return true
        }
    }

    // MARK: loading

    // Assigned only when they differ: an observed property tells its views even when it's given the
    // same value, and every chat's summary comes again after each turn.

    func setInfo(_ i: ThreadInfo) {
        if info != i { info = i }
        if status != i.status { status = i.status }
        refreshTitle()
    }

    func setSummary(_ s: ThreadSummary) {
        if summary != s { summary = s }
        if info == nil, status != s.status { status = s.status }
        // A chat the daemon hasn't loaded runs nothing; a server too old to count says nothing.
        let count = s.backgroundTasks ?? (s.status == .notLoaded ? 0 : backgroundTaskCount)
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
            for case .text(let t) in m.content { return String(t.text.prefix(80)) }
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

    /// Replace transcript with server history (thread/read or thread/resume includeHistory).
    /// `fileChanges` are the page's edits, counted off the main actor.
    func loadHistory(items newItems: [Item], turns newTurns: [Turn], seq: Int?, hasMore: Bool = false,
                     fileChanges changes: [String: [FileChange]] = [:]) {
        if let seq { lastSeq = seq }
        remember(changes)
        storage = newItems
        if turns != newTurns { turns = newTurns }
        noteLastTurn()
        if awaitingPrompt { awaitingPrompt = false }
        reindex()
        if hasMoreHistory != hasMore { hasMoreHistory = hasMore }
        if !historyLoaded { historyLoaded = true }
    }

    /// Add an older page to the front. `fileChanges` are its edits, counted off the main actor.
    func prependHistory(items older: [Item], hasMore: Bool, fileChanges changes: [String: [FileChange]] = [:]) {
        if hasMoreHistory != hasMore { hasMoreHistory = hasMore }
        remember(changes)
        let fresh = older.filter { index[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        storage.insert(contentsOf: fresh, at: 0)
        reindex()
    }

    /// Changes counted ahead of drawing, for the calls not already counted.
    func remember(_ changes: [String: [FileChange]]) {
        for (id, c) in changes where fileChanges[id] == nil { fileChanges[id] = c }
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
        subagentCallIDs = []
        for (i, item) in storage.enumerated() {
            if let parent = item.parentToolUseId { childIndexes[parent, default: []].append(i) }
            if item.isSubagentCall { subagentCallIDs.append(item.id) }
        }
        // Every index may have moved: all the rows fold again.
        refoldFrom = 0
        itemsVersion &+= 1
        childrenVersion &+= 1
        if let id = streamingReplyID, index[id] == nil { setStreamingReply(nil) }
        refreshTaskEntries()
        refreshTitle()
    }

    /// Drops the transcript so the next open reads it afresh.
    func unload() {
        fileChanges = [:]
        started = [:]
        openingPrompt = nil
        storage = []
        turns = []
        tasks = [:]
        taskIDsByToolUse = [:]
        backgroundTaskIDs = []
        reindex()
        dropDerived()
        lastSeq = 0
        hasMoreHistory = false
        historyLoaded = false
    }

    /// Keeps only the last `count` items of a chat no window shows, and nothing worked out from
    /// them. Its place in the stream stays as it is — `lastSeq`, the turns, the tasks still running —
    /// so live events go on applying after it with no gap or overlap, and the items let go load
    /// again a page at a time when it's shown and scrolled back (`hasMoreHistory`).
    func trim(toLast count: Int) {
        defer { dropDerived() }
        guard historyLoaded, storage.count > count else { return }
        // Its title stays the prompt it opened with, until Claude names it.
        if openingPrompt == nil { openingPrompt = Self.firstPrompt(in: storage) }
        storage.removeFirst(storage.count - count)
        started = [:]
        let held = Set(storage.map(\.id))
        // A finished task whose call went with the older items isn't listed, as with a page loaded
        // afresh; one still running is, so it can still be stopped.
        tasks = tasks.filter { _, task in
            task.toolUseId.map(held.contains) ?? true || InspectorTaskEntry.isRunning(task)
        }
        indexTasks()
        reindex()
        fileChanges = fileChanges.filter { held.contains($0.key) }
        if !hasMoreHistory { hasMoreHistory = true }
    }

    /// Lets go of what's worked out from the items, all of it made again when it's next asked for.
    private func dropDerived() {
        cachedTopLevel = nil
        cachedRows = nil
        folded = nil
        refoldFrom = 0
    }

    // MARK: notifications

    /// Returns false for a notification already applied (a replay overlap, or a stale stream's).
    @discardableResult
    func apply(_ n: ServerNotification) -> Bool {
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
            if status != e.status {
                if !isRunning, e.status == .running, currentTurn == nil, !awaitingPrompt { awaitingPrompt = true }
                status = e.status
            }
            if activity != e.activity?.rawValue { activity = e.activity?.rawValue }
            if let count = e.backgroundTasks, count != backgroundTaskCount { backgroundTaskCount = count }
            if e.status == .idle, apiRetry != nil { apiRetry = nil }
        case .threadClosed:
            status = .closed
            // Its background tasks ended with its process.
            if backgroundTaskCount != 0 { backgroundTaskCount = 0 }
            settleTasks()
            setStreamingReply(nil)
        case .turnStarted(let e):
            Signposts.replyStarted(in: self)
            upsertTurn(e.turn)
            promptSuggestion = nil
            if !awaitingPrompt { awaitingPrompt = true }
        case .turnCompleted(let e):
            Signposts.replyEnded(in: self)
            upsertTurn(e.turn)
            if awaitingPrompt { awaitingPrompt = false }
            setStreamingReply(nil)
        case .itemStarted(let e):
            if index[e.item.id] == nil {
                noteStarted(e.item.id)
                if case .userMessage(let m) = e.item, m.parentToolUseId == nil { arrivedPrompt = m.id }
                if awaitingPrompt { awaitingPrompt = false }
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
        case .taskEvent(let e):
            let previous = tasks[e.taskId]
            let task = merged(e, into: previous)
            tasks[e.taskId] = task
            if previous?.toolUseId != nil, previous?.toolUseId != task.toolUseId {
                indexTasks() // moved to another call, which never happens in practice
            } else if let toolUseId = task.toolUseId {
                // The latest event is this one, so its task is the call's newest.
                taskIDsByToolUse[toolUseId] = task.taskId
            }
            refreshTaskEntries()
        case .taskBackgroundChanged(let e):
            let ids = Set((e.tasks.arrayValue ?? []).compactMap { $0["task_id"]?.stringValue })
            if ids != backgroundTaskIDs { backgroundTaskIDs = ids }
            refreshTaskEntries()
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

    func addPending(_ p: PendingRequest) {
        pending.removeAll { $0.id == p.id }
        pending.append(p)
    }

    /// Answer a prompt. The server broadcasts serverRequest/resolved to every client.
    /// A suggested task started or dismissed.
    public func dismissSuggestedTask(_ id: UUID) {
        suggestedTasks.removeAll { $0.id == id }
    }

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

    /// A task's latest event, keeping what earlier ones said: only `started` carries the
    /// description, and an `updated` patch can omit the tool call the task belongs to.
    private func merged(_ event: TaskEventNotification, into previous: TaskEventNotification?) -> TaskEventNotification {
        guard let previous else { return event }
        var event = event
        if event.toolUseId == nil { event.toolUseId = previous.toolUseId }
        if event.description == nil { event.description = previous.description }
        if event.summary == nil { event.summary = previous.summary }
        if event.status == nil { event.status = previous.status }
        // Only `started` says what kind of task it is.
        if case .object(var data) = event.data, data["task_type"] == nil, let type = previous.data["task_type"] {
            data["task_type"] = type
            event.data = .object(data)
        }
        return event
    }

    /// The thread's process has ended, and every task it was running with it; none will report again.
    private func settleTasks() {
        if !backgroundTaskIDs.isEmpty { backgroundTaskIDs = [] }
        for (id, task) in tasks where InspectorTaskEntry.isRunning(task) {
            var stopped = task
            stopped.status = "stopped"
            tasks[id] = stopped
        }
        refreshTaskEntries()
    }

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
        if let i = turns.lastIndex(where: { $0.id == t.id }) { turns[i] = t } else { turns.append(t) }
        noteLastTurn()
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
        if let previous, previous.parentToolUseId != item.parentToolUseId || previous.isSubagentCall != item.isSubagentCall {
            reindex() // an item moved between cards, which never happens in practice
        } else {
            noteChange(of: item, at: i, isNew: previous == nil, was: previous)
        }
        if item.isSubagentCall { refreshTaskEntries() }
        if case .toolCall(let call) = item, call.changesFiles, fileChanges[id] == nil { countChanges(of: call) }
        // Only an opening user message can move the title, and only until Claude names the session.
        if isUnnamed, case .userMessage(let m) = item, m.synthetic != true { refreshTitle() }
    }

    /// What an item added or replaced changes: the rows, from its turn on, when it's the chat's own
    /// or an edit (a subagent's edits count in its turn's); its subagent's card, when it's a
    /// subagent's.
    private func noteChange(of item: Item, at i: Int, isNew: Bool, was previous: Item?) {
        if let parent = item.parentToolUseId {
            if isNew { childIndexes[parent, default: []].append(i) }
            childrenVersion &+= 1
        }
        if isNew, item.isSubagentCall { subagentCallIDs.append(item.id) }
        if item.parentToolUseId == nil || item.isEditCall || previous?.isEditCall == true {
            refoldFrom = min(refoldFrom, i)
            itemsVersion &+= 1
        }
    }

    /// Counts a finished edit's changes off the main actor, for its turn's edits once it ends.
    private func countChanges(of call: Item.ToolCall) {
        Task { [weak self] in
            let changes = await FileChange.changes(ofCallsIn: [.toolCall(call)])
            // Unless it was let go meanwhile.
            guard let self, self.index[call.id] != nil else { return }
            self.remember(changes)
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
    func settleArrivals() { started = [:] }
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
        if storage[i].isSubagentCall { refreshTaskEntries() }
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
    /// but never shown. What the live run of calls and the Thinking line go by.
    public var lastShownItem: Item? {
        items.last { item in
            if case .reasoning = item { return false }
            return item.parentToolUseId == nil
        }
    }

    /// Claude's messages in the turn that ends with `id`, in order: what the turn's Copy copies.
    public func turnReplies(through id: String) -> [String] {
        guard var i = index[id] else { return [] }
        var texts: [String] = []
        while i >= 0 {
            switch storage[i] {
            case .userMessage(let m) where m.synthetic != true && m.parentToolUseId == nil && m.origin == nil:
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

    /// Items belonging to a subagent (Task/Agent tool) — rendered nested in its card. Observes the
    /// subagents' items, not the transcript's.
    public func children(of toolUseId: String) -> [Item] {
        _ = childrenVersion
        return childIndexes[toolUseId]?.map { storage[$0] } ?? []
    }

    /// The newest lifecycle event for a subagent tool call (task IDs aren't tool-use IDs).
    public func taskEvent(forToolUseId toolUseId: String) -> TaskEventNotification? {
        taskIDsByToolUse[toolUseId].flatMap { tasks[$0] }
    }

    /// Background state arrives either as a task event patch or as the SDK's full list.
    public func isTaskBackgrounded(toolUseId: String) -> Bool {
        taskEvent(forToolUseId: toolUseId).map(isBackgrounded) ?? false
    }

    private func isBackgrounded(_ task: TaskEventNotification) -> Bool {
        backgroundTaskIDs.contains(task.taskId)
            || task.data["is_backgrounded"]?.boolValue == true
            || task.data["patch"]?["is_backgrounded"]?.boolValue == true
    }

    /// `taskIDsByToolUse` from `tasks` as they are: each call's task with the latest event.
    private func indexTasks() {
        taskIDsByToolUse = [:]
        for task in tasks.values {
            guard let toolUseId = task.toolUseId else { continue }
            if let current = taskIDsByToolUse[toolUseId], let other = tasks[current], other.seq >= task.seq { continue }
            taskIDsByToolUse[toolUseId] = task.taskId
        }
    }

    public var topLevelItems: [Item] {
        if let c = cachedTopLevel, c.version == itemsVersion { return c.items }
        let top = storage.filter { $0.parentToolUseId == nil }
        cachedTopLevel = (itemsVersion, top)
        return top
    }

    /// The top-level items with consecutive finished tool calls folded into one row, before the
    /// dates and edits go between turns. The transcript draws `rows(_:)`.
    public var rows: [TranscriptRow] {
        if let c = cachedRows, c.version == itemsVersion { return c.rows }
        let rows = foldTranscriptRows(topLevelItems)
        cachedRows = (itemsVersion, rows)
        return rows
    }

    /// The transcript as it is drawn: the rows folded as View ▸ Tool Calls says, with
    /// the date above a prompt after a break and the files each finished turn edited after it. The
    /// edits, and Worked For's folding, depend on whether the last turn is still running.
    ///
    /// The same as folding and decorating every item at once, made a turn at a time: a finished
    /// turn's rows are kept, and only the turns from the first item changed since fold again, which
    /// while a turn runs is that turn alone.
    public func rows(_ folding: TranscriptFolding) -> [TranscriptRow] {
        foldedRows(folding).rows
    }

    /// The reader's own prompts among `rows(folding)`, for VoiceOver's Prompts rotor. Made with the
    /// rows, so drawing the transcript doesn't go through all of them again.
    public func prompts(_ folding: TranscriptFolding) -> [TranscriptPrompt] {
        foldedRows(folding).prompts
    }

    /// The rows as one folding draws them, and where each turn's are among them.
    private struct FoldedRows {
        let folding: TranscriptFolding
        var version = 0
        var running = false
        var rows: [TranscriptRow] = []
        var prompts: [TranscriptPrompt] = []
        var turns: [Span] = []

        /// One turn's place in `storage` and among the rows.
        struct Span {
            /// Where the turn is in `storage`: from its prompt, or the first item held, up to the next prompt.
            let items: Range<Int>
            /// Where its rows and prompts end in `rows` and `prompts`.
            let rowsEnd: Int
            let promptsEnd: Int
            /// What the date separators carry into the next turn.
            let dates: DateSeparators.Carry
        }
    }

    private func foldedRows(_ folding: TranscriptFolding) -> FoldedRows {
        let running = isRunning
        let version = itemsVersion
        if let f = folded, f.folding == folding, f.version == version, f.running == running { return f }
        var f = folded.flatMap { $0.folding == folding ? $0 : nil } ?? FoldedRows(folding: folding)
        // Edited in place rather than copied.
        folded = nil
        // The turns that end before the first change stay as they are. The last one held always
        // folds again: the items it's given, and whether it's running, change as it runs.
        var kept = 0
        while kept < f.turns.count - 1, f.turns[kept].items.upperBound < refoldFrom { kept += 1 }
        let last = kept > 0 ? f.turns[kept - 1] : nil
        f.turns.removeSubrange(kept...)
        f.rows.removeSubrange((last?.rowsEnd ?? 0)...)
        f.prompts.removeSubrange((last?.promptsEnd ?? 0)...)
        var dates = last?.dates ?? DateSeparators.Carry()
        var start = last?.items.upperBound ?? 0
        while start < storage.count {
            var end = start + 1
            while end < storage.count, !storage[end].isPrompt { end += 1 }
            let rows = transcriptRows(ofTurn: storage[start..<end], folding: folding, running: running && end == storage.count,
                                      dates: &dates) { self.changes(of: $0) }
            f.rows += rows
            f.prompts += TranscriptPrompt.list(in: rows)
            f.turns.append(.init(items: start..<end, rowsEnd: f.rows.count, promptsEnd: f.prompts.count, dates: dates))
            start = end
        }
        f.version = version
        f.running = running
        refoldFrom = .max
        folded = f
        return f
    }

    /// The foldings whose rows are held, for tests: the current one's alone.
    var foldingsHeld: [TranscriptFolding] { folded.map { [$0.folding] } ?? [] }

    /// How many items, or things made from them, the thread holds on to, for tests: the transcript,
    /// its boxes, and what's worked out from it.
    var itemsHeld: Int {
        storage.count + boxes.count + (cachedTopLevel?.items.count ?? 0) + (cachedRows?.rows.count ?? 0)
            + (folded?.rows.count ?? 0) + childIndexes.values.reduce(0) { $0 + $1.count } + subagentCallIDs.count
            + fileChanges.count + started.count
    }

    private func changes(of call: Item.ToolCall) -> [FileChange] {
        // Every other call changed nothing, and takes nothing to say so.
        guard call.changesFiles else { return [] }
        if let known = fileChanges[call.id] { return known }
        changesCountedOnMainActor += 1
        let changes = FileChange.changes(of: call)
        fileChanges[call.id] = changes
        return changes
    }

    /// Subagent and workflow runs, as the Tasks inspector lists them: every subagent tool call,
    /// then the tasks the SDK reported that no call of ours matches.
    ///
    /// Stored, and rebuilt only when `tasks`, `backgroundTaskIDs` or a subagent call changes: computed
    /// from `items` it would make every streamed delta invalidate the Tasks inspector. Assigned only
    /// when it changes, so an event that changes nothing shown redraws nothing.
    public private(set) var taskEntries: [InspectorTaskEntry] = []

    private func refreshTaskEntries() {
        // Includes agents launched by other agents, which have no top-level row.
        var matchedTaskIDs = Set<String>()
        var entries: [InspectorTaskEntry] = []
        entries.reserveCapacity(subagentCallIDs.count)
        for id in subagentCallIDs {
            guard let i = index[id], case .toolCall(let call) = storage[i] else { continue }
            let task = taskEvent(forToolUseId: id)
            if let task { matchedTaskIDs.insert(task.taskId) }
            entries.append(InspectorTaskEntry(id: id, call: call, task: task, isBackgrounded: task.map(isBackgrounded) ?? false))
        }
        entries += tasks.values
            .filter { !matchedTaskIDs.contains($0.taskId) }
            .sorted { $0.seq < $1.seq }
            .map {
                InspectorTaskEntry(
                    id: "task:\($0.taskId)",
                    call: nil,
                    task: $0,
                    isBackgrounded: backgroundTaskIDs.contains($0.taskId)
                )
            }
        if entries != taskEntries { taskEntries = entries }
    }

    /// Position of an item in the transcript, for views that need to know what came after it.
    public func itemIndex(of id: String) -> Int? { index[id] }
}

private extension Item {
    var isSubagentCall: Bool {
        if case .toolCall(let call) = self { return call.kind == .subagent }
        return false
    }

    /// A call that edits files, finished or not: its changes count in its turn's edits.
    var isEditCall: Bool {
        guard case .toolCall(let call) = self else { return false }
        return call.kind == .fileEdit || call.kind == .fileWrite || call.kind == .notebookEdit
    }

    /// A prompt of the chat's own, where a turn starts.
    internal var isPrompt: Bool {
        if case .userMessage(let m) = self { return m.parentToolUseId == nil }
        return false
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

/// One subagent or workflow run: the tool call that started it, its newest lifecycle event, or both.
public struct InspectorTaskEntry: Identifiable, Equatable {
    public let id: String
    public let call: Item.ToolCall?
    public let task: TaskEventNotification?
    public let isBackgrounded: Bool

    /// The CLI still has a task for it: it can be stopped or, while it blocks the turn, backgrounded.
    public var isTaskRunning: Bool { task.map(Self.isRunning) ?? false }

    static func isRunning(_ task: TaskEventNotification) -> Bool {
        task.event != "notification" && !["completed", "failed", "stopped", "killed"].contains(task.status ?? "")
    }

    /// Only a command or an agent can be sent to the background (the CLI's Control-B).
    public var canMoveToBackground: Bool {
        guard isTaskRunning, !isBackgrounded, task?.toolUseId != nil else { return false }
        return ["local_bash", "local_agent"].contains(task?.data["task_type"]?.stringValue ?? "")
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
    public func isCurrent(at now: Date) -> Bool {
        resetsAt.map { $0 > now } ?? true
    }

    /// What the status strip says about the limit at `now`: nothing while requests go through as
    /// usual or once it has reset; otherwise how much is used, or that it's reached, and when it
    /// resets.
    public func warning(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard status != .allowed, isCurrent(at: now) else { return nil }
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
