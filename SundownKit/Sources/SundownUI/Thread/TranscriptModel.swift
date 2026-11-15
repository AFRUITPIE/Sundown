import AppKit
import OSLog
import SwiftUI
import SundownKit

/// The transcript's rows and the reader's place in them, for `TranscriptView`.
///
/// - Rows: the chat's rows split in two at the last turn's prompt (`TranscriptSplit`): settled
///   history, drawn windowed by `TranscriptHistoryView`, and the live turn, drawn whole by
///   `TranscriptLiveView`. A streamed delta reaches only the live turn's rows (through their items'
///   boxes); history isn't redrawn, measured again or diffed for it.
/// - Heights: every settled row's height at the current width is known before the row is built
///   (`HeightIndex`), from its text for a message (`RowMeasurer`, TextKit off the main thread) or
///   measured once for anything else, so which rows to build, and every place the reader is taken
///   to, is arithmetic. A built row says its height; one that differs corrects the index (and is
///   logged in Debug builds: `TranscriptHeights`), with the reader's place kept.
/// - Place: at the end, the scroll position is the bottom edge, which follows the end as it grows;
///   scrolled up, it's the row at the top of the view and how far into it, put back after any
///   change above it (an older page, a correction, a new width) in the same update as the change.
@MainActor @Observable
final class TranscriptModel {
    static let log = Logger(subsystem: "com.haydenhong.Sundown", category: "TranscriptHeights")
    /// Between rows.
    static let spacing: CGFloat = 14
    /// Above the first row, under the toolbar.
    static let topPadding: CGFloat = 16
    /// The older-history row's fixed height, so the rows under it start at a known place.
    static let olderRowHeight: CGFloat = 36

    // MARK: What the views draw

    var settled: [TranscriptEntry] = []
    var index = HeightIndex(spacing: spacing)
    /// The settled rows built: those near the view.
    var window: Range<Int> = 0..<0 {
        didSet {
            guard window != oldValue else { return }
            buildAhead()
            refreshStale()
        }
    }
    var live: [TranscriptEntry] = []
    /// The history is measured and shown.
    var ready = false
    /// Older history is there to load: its row is above the rows.
    var showsOlder = false
    var olderFailed = false
    /// More than a screen from the end: Jump to Latest is offered.
    var farFromEnd = false
    /// Bumped by each place the model takes the reader (`scroll(_:)`), and read by the position's
    /// getter, which `TranscriptView`'s key-path binding calls in its body: so each request redraws
    /// it and reaches the scroll view.
    var positionRequests = 0
    /// The scroll view's position: the model's requests, and what the scroll view writes back as it
    /// resolves them or the reader scrolls, which is kept out of observation. Observed, a write-back
    /// redrew `TranscriptView` on every frame the end was followed (streaming cost a fifth more) and
    /// inside the layout pass resolving it; and asked for from a scroll geometry callback inside that
    /// pass, each request was resolved and written back there, laying the transcript out again,
    /// which asked again: during a live resize that never returned (100% CPU, 2026-11). Requests
    /// from geometry callbacks go after the pass (`followEndSoon`).
    @ObservationIgnored var storedPosition = ScrollPosition(edge: .bottom)
    var position: ScrollPosition {
        get {
            _ = positionRequests
            return storedPosition
        }
        set { storedPosition = newValue }
    }
    /// The bottom edge was asked for and the reader hasn't scrolled away since: the scroll view
    /// follows the end as it grows.
    @ObservationIgnored var edgeArmed = true

    // MARK: Rows and heights

    @ObservationIgnored private(set) var thread: ThreadModel?
    @ObservationIgnored var connection: HostConnection?
    @ObservationIgnored private(set) var folding: TranscriptFolding = .summarized
    @ObservationIgnored let measurer = RowMeasurer()
    /// Puts the reader back after the rows change under them (`ScrollKeeper`).
    @ObservationIgnored weak var keeper: ScrollKeeperView?
    /// Which rows are open, kept while they aren't built.
    @ObservationIgnored let expansion = RowExpansion()
    /// The width rows are laid out at.
    @ObservationIgnored var width: CGFloat = 0
    /// The live turn's rows' heights, as they last said them.
    @ObservationIgnored var liveHeights: [String: CGFloat] = [:]
    /// Settled rows measured for an earlier width or text size, until they're measured again.
    @ObservationIgnored var stale: Set<String> = []
    /// Rows that have said their height at this width; a later change is the row's own (a
    /// disclosure opened), not a wrong prediction.
    @ObservationIgnored private var reported: Set<String> = []
    /// Heights of rows another folding showed, at this width and text size, for coming back to it.
    @ObservationIgnored private var otherFolding: [String: (entry: TranscriptEntry, height: CGFloat)] = [:]
    /// The settled rows' heights at the last few widths, for a width coming back (snapping a window
    /// between halves and full screen): those rows aren't measured again.
    @ObservationIgnored private var byWidth: [(width: CGFloat, heights: [String: (entry: TranscriptEntry, height: CGFloat)])] = []
    /// Rows measured for the next commit, which waits for them.
    @ObservationIgnored private var pending: [String: (entry: TranscriptEntry, height: CGFloat)] = [:]
    @ObservationIgnored private var measuring: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    /// A window is in a live resize (`watchLiveResize`).
    @ObservationIgnored private var resizingLive = false
    /// Waiting for the next change to the settled rows (`settledHolds`).
    @ObservationIgnored var commitWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var watching = false

    // MARK: The reader's place

    @ObservationIgnored var view = ViewGeometry()
    /// At the end, staying there as the rows grow.
    @ObservationIgnored var following = true
    /// The prompt Previous or Next Prompt last went to, until the reader scrolls for themselves.
    @ObservationIgnored var lastPrompt: String?
    /// Under Tasks or Diff: the geometry isn't the reader's. Shown again, the rows built are
    /// worked out afresh from where the view is: while hidden, a change of place (an older page
    /// going in) moved the view without its rows following, and coming back from Tasks showed none
    /// until the reader scrolled (CI, 2026-11).
    @ObservationIgnored var hidden = false {
        didSet { if oldValue, !hidden { buildRowsInView() } }
    }
    /// The offset the view is being taken to: SwiftUI reports the content laid out anew at the old
    /// offset first, which is never drawn and isn't the reader (it asked for a second older page).
    @ObservationIgnored var landing: CGFloat? { didSet { landingSkips = 0 } }
    @ObservationIgnored var landingSkips = 0
    /// The bottom edge is asked for after this layout pass (`followEndSoon`).
    @ObservationIgnored var endPending = false
    @ObservationIgnored var buildingAhead: Task<Void, Never>?
    @ObservationIgnored var loadingOlder = false
    @ObservationIgnored var olderFailures = 0
    /// The view has been at the end since the history was shown: until then the geometry is the
    /// empty transcript's, at its top, which isn't the reader nearing the top.
    @ObservationIgnored var arrived = false

    #if DEBUG
    @ObservationIgnored private(set) var mismatches: [String: Int] = [:]
    #endif

    init() {
        measurer.expansion = expansion
        watchLiveResize()
        #if DEBUG
        listenToStressDriver()
        #endif
    }

    // MARK: From the view

    func show(_ thread: ThreadModel, connection: HostConnection?, folding: TranscriptFolding) {
        self.connection = connection
        guard thread !== self.thread || folding != self.folding else { return }
        if thread !== self.thread {
            resumeWaiters()
            self.thread = thread
            settled = []
            index = HeightIndex(spacing: Self.spacing)
            live = []
            liveHeights = [:]
            ready = false
            arrived = false
            following = true
            watching = false
        }
        if folding != self.folding {
            for (i, entry) in settled.enumerated() { otherFolding[entry.id] = (entry, index.height(i)) }
        }
        self.folding = folding
        modelChanged()
    }

    /// The transcript's environment: what rows measured off screen are drawn with.
    func environment(_ values: EnvironmentValues) {
        measurer.environment = values
        guard measurer.setMetrics(RowMetrics(values)) else { return }
        // A new text size or reading width: every height again.
        remeasureAll()
    }

    /// The width the rows are laid out at.
    func widthChanged(_ new: CGFloat) {
        guard new >= 200, abs(new - width) >= 0.5 else { return }
        if ready, !resizingLive { rememberWidth() }
        width = new
        if !ready {
            modelChanged()
        } else {
            remeasureAll(widthOnly: true)
        }
    }

    // MARK: Rows

    /// Applies the chat's rows, once the settled ones all have heights, then watches for the next
    /// change. Idempotent.
    func modelChanged() {
        guard let thread else { return }
        watch(thread)
        guard thread.historyLoaded, width >= 200, measurer.calibrate(thread: thread, width: width) else { return }
        let rows = thread.rows(folding)
        let places = TurnPlaces(rows, prompts: thread.prompts(folding), running: thread.isRunning)
        let entries = rows.map { row in
            TranscriptEntry(row: row, place: places.turns[row.id].map { TurnPlace(turn: $0, isEnd: places.ends.contains(row.id)) })
        }
        let split = TranscriptSplit.liveStart(rows)
        let newSettled = Array(entries[..<split]), newLive = Array(entries[split...])

        // Each settled row's height: kept, said by the live turn it was in, or measured for it.
        var heights: [CGFloat] = []
        heights.reserveCapacity(newSettled.count)
        var missing: [TranscriptEntry] = []
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in newSettled {
            if let j = index.index(of: entry.id), settled[j].drawsSame(as: entry, thread: thread) {
                heights.append(index.height(j))
            } else if let was = liveByID[entry.id], let h = liveHeights[entry.id], was.drawsSame(as: entry, thread: thread) {
                heights.append(h)
                reported.insert(entry.id)
            } else if let p = pending[entry.id] ?? otherFolding[entry.id], p.entry.drawsSame(as: entry, thread: thread) {
                heights.append(p.height)
            } else {
                heights.append(0)
                missing.append(entry)
            }
        }
        guard missing.isEmpty else {
            measure(missing)
            return
        }
        commit(newSettled, heights: heights, live: newLive)
    }

    private func commit(_ newSettled: [TranscriptEntry], heights: [CGFloat], live newLive: [TranscriptEntry]) {
        guard let thread else { return }
        let keep = place()
        let first = !ready
        let settledChanged = newSettled.count != settled.count || newSettled.indices.contains { i in
            newSettled[i].id != settled[i].id || index.height(i) != heights[i] || !newSettled[i].drawsSame(as: settled[i], thread: thread)
        }
        let liveChanged = newLive.count != live.count || newLive.indices.contains { i in
            newLive[i].id != live[i].id || !newLive[i].drawsSame(as: live[i], thread: thread)
        }
        let older = thread.hasMoreHistory
        pending = [:]
        guard settledChanged || liveChanged || older != showsOlder || first else { return }
        if settledChanged {
            let ids = Set(newSettled.map(\.id))
            stale.formIntersection(ids)
            reported.formIntersection(ids.union(newLive.map(\.id)))
            settled = newSettled
            index = HeightIndex(ids: newSettled.map(\.id), heights: heights, spacing: Self.spacing)
        }
        if liveChanged {
            live = newLive
            let ids = Set(newLive.map(\.id))
            liveHeights = liveHeights.filter { ids.contains($0.key) }
        }
        let olderChanged = older != showsOlder
        if olderChanged { showsOlder = older }
        if !ready { ready = true }
        // Opening at the end: the end as the rows are first laid out, not of the empty content.
        // The live turn alone changing moves nothing above it: at the end the bottom edge already
        // follows it, and scrolled up the reader's row is where it was, unless it's in that turn.
        if first {
            goToEnd(reader: false, moved: true)
        } else if settledChanged || olderChanged {
            restore(keep)
        } else if case .live = keep {
            restore(keep)
        }
        if loadingOlder, settledChanged { loadingOlder = false }
        if settledChanged { resumeWaiters() }
    }

    func resumeWaiters() {
        let waiters = commitWaiters
        commitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Measures rows the next commit needs, then tries it again.
    private func measure(_ entries: [TranscriptEntry]) {
        guard measuring == nil, let thread else { return }
        let width = width
        measuring = Task { [weak self] in
            guard let self else { return }
            let heights = await self.heights(of: entries, thread: thread, width: width, keepBuilt: 40)
            self.measuring = nil
            guard width == self.width, self.thread === thread else { self.modelChanged(); return }
            for (entry, h) in zip(entries, heights) { self.pending[entry.id] = (entry, h) }
            self.modelChanged()
        }
    }

    /// Rows' heights at `width`: messages' text off the main thread, other rows measured here a few
    /// at a time, so a page of them doesn't hold up a frame.
    private func heights(of entries: [TranscriptEntry], thread: ThreadModel, width: CGFloat,
                         keepBuilt: Int = 0) async -> [CGFloat] {
        guard measurer.calibrate(thread: thread, width: width) else { return entries.map { _ in 0 } }
        var shapes: [TextShape?] = []
        var jobs: [TextJob] = []
        for entry in entries {
            let shape = TextShape(entry, thread: thread)
            shapes.append(shape)
            if let shape { jobs += measurer.textJobs(shape, width: width) }
        }
        let metrics = measurer.metrics
        // The last rows' built text kept: those nearest the reader as a chat opens or a page goes in
        // above them, built here anyway.
        let (texts, built) = jobs.isEmpty ? ([], []) : await TextHeights.heights(jobs, scale: metrics.textScale,
                                                                                 increasedContrast: metrics.increasedContrast,
                                                                                 keeping: min(jobs.count, keepBuilt))
        for b in built { MarkdownView.Coordinator.keep(b.string, for: b.text, theme: b.theme) }
        var out: [CGFloat] = []
        out.reserveCapacity(entries.count)
        var next = 0, sized = 0
        for (entry, shape) in zip(entries, shapes) {
            if let shape {
                let n = shape.texts.count
                out.append(measurer.height(shape, texts: Array(texts[next..<next + n])))
                next += n
            } else {
                out.append(measurer.measured(entry, thread: thread, width: width))
                sized += 1
                if sized % 24 == 0 { await Task.yield() }
            }
        }
        return out
    }

    /// The model's next change to the rows, applied once it has happened.
    private func watch(_ thread: ThreadModel) {
        guard !watching else { return }
        watching = true
        let folding = folding
        withObservationTracking {
            _ = thread.rows(folding)
            _ = thread.historyLoaded
            _ = thread.hasMoreHistory
            _ = thread.isRunning
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.thread === thread else { return }
                self.watching = false
                self.modelChanged()
            }
        }
    }

    // MARK: Heights said by the rows

    /// A built row's height as it laid out.
    func reported(_ height: CGFloat, for id: String, live isLive: Bool) {
        let h = RowMeasurer.rounded(height)
        if isLive {
            liveHeights[id] = h
            return
        }
        guard let i = index.index(of: id) else { return }
        let old = index.height(i)
        let first = reported.insert(id).inserted
        guard abs(h - old) >= 0.5 else {
            stale.remove(id)
            return
        }
        #if DEBUG
        // A stale row's height was for another width: expected to differ, and not a wrong prediction.
        if !stale.contains(id) {
            let why = first ? "predicted" : "changed"
            let kind = settled[i].kind
            mismatches["\(kind) \(why)", default: 0] += 1
            Self.log.error("Height \(why, privacy: .public) \(kind, privacy: .public) \(id, privacy: .public): index \(old) row \(h) width \(self.width)")
        }
        #endif
        stale.remove(id)
        let keep = place()
        index.setHeight(h, at: i)
        restore(keep)
    }

    /// Every settled row measured again, for a new text size, or every message for a new width:
    /// those built now, so what's on screen is right at once, then the rest from the nearest out,
    /// a batch at a time, the reader's place kept as each lands.
    private func remeasureAll(widthOnly: Bool = false) {
        guard ready, let thread else { modelChanged(); return }
        stopRefreshing()
        guard measurer.calibrate(thread: thread, width: width) else { return }
        reported = []
        otherFolding = [:]
        // A new width changes what wraps: messages' text. Other rows are a line or a few at any
        // width the window allows, so they keep their heights except those built now; one that
        // does wrap says so when it's built (logged as stale).
        stale = Set(settled.filter { !widthOnly || TextShape($0, thread: thread) != nil }.map(\.id))
        if !widthOnly { byWidth = [] }
        let keep = place()
        // Rows known at this width from before, drawn the same since.
        if let known = byWidth.first(where: { abs($0.width - width) < 0.5 })?.heights {
            var changes: [(index: Int, height: CGFloat)] = []
            for (i, entry) in settled.enumerated() where stale.contains(entry.id) {
                guard let k = known[entry.id], k.entry.drawsSame(as: entry, thread: thread) else { continue }
                stale.remove(entry.id)
                changes.append((i, k.height))
            }
            index.setHeights(changes)
        }
        // Of the rows built, only those down to the reader's row decide where the view goes, so
        // only they are laid out here, ahead of their views; the rows after it say their heights
        // as they lay out, which moves nothing the reader sees. At the end, that's every row.
        // Measuring all of them here laid each built message out twice per step of a resize, a
        // fifth of what a live resize cost (2026-11).
        let built = window.clamped(to: 0..<settled.count)
        let near: Range<Int> = switch keep {
        case .end: built.lowerBound..<built.lowerBound
        case .row(let id, _, _, _): built.lowerBound..<min(built.upperBound, max(built.lowerBound, (index.index(of: id) ?? built.upperBound - 1) + 1))
        case .live, .top: built
        }
        let changes = near.map { i in (i, measurer.heightNow(settled[i], thread: thread, width: width)) }
        for i in near { stale.remove(settled[i].id) }
        index.setHeights(changes)
        restore(keep)
        refreshStale()
    }

    /// The settled rows' heights at the width they're at, before it changes; the last four widths.
    private func rememberWidth() {
        var heights: [String: (entry: TranscriptEntry, height: CGFloat)] = [:]
        heights.reserveCapacity(settled.count)
        for (i, entry) in settled.enumerated() where !stale.contains(entry.id) { heights[entry.id] = (entry, index.height(i)) }
        byWidth.removeAll { abs($0.width - width) < 0.5 }
        byWidth.append((width, heights))
        if byWidth.count > 4 { byWidth.removeFirst() }
    }

    /// Stale rows within this many of the view are measured again in the background; farther ones
    /// as the view comes near them (`window`), so a new width doesn't re-lay out every message of a
    /// long chat, most of which the reader may never come back to.
    static let refreshReach = 300

    /// Measures stale rows near the view, a batch at a time from the nearest out, the reader's place
    /// kept as each lands. Not during a window's live resize: the rows built are measured at each
    /// step, and the rest once it ends.
    func refreshStale() {
        guard refreshing == nil, !resizingLive, let thread, !stale.isEmpty else { return }
        let width = width
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshing = Task { [weak self] in
            while let self, !Task.isCancelled {
                let center = self.window.isEmpty ? self.settled.count : (self.window.lowerBound + self.window.upperBound) / 2
                let near = max(0, center - Self.refreshReach)..<min(self.settled.count, center + Self.refreshReach)
                let batch = near.filter { self.stale.contains(self.settled[$0].id) }
                    .sorted { abs($0 - center) < abs($1 - center) }.prefix(64).map { self.settled[$0] }
                guard !batch.isEmpty else { break }
                let heights = await self.heights(of: batch, thread: thread, width: width)
                guard !Task.isCancelled, width == self.width else { break }
                let keep = self.place()
                var changes: [(index: Int, height: CGFloat)] = []
                for (entry, h) in zip(batch, heights) {
                    guard let i = self.index.index(of: entry.id), self.stale.remove(entry.id) != nil else { continue }
                    if abs(self.index.height(i) - h) >= 0.5 { changes.append((i, h)) }
                }
                if !changes.isEmpty {
                    self.index.setHeights(changes)
                    self.restore(keep)
                }
                await Task.yield()
            }
            if let self, self.refreshGeneration == generation { self.refreshing = nil }
        }
    }

    private func stopRefreshing() {
        refreshing?.cancel()
        refreshing = nil
    }

    /// A window's live resize: the background measuring waits for its end.
    private func watchLiveResize() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizingLive = true
                self?.stopRefreshing()
            }
        }
        center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizingLive = false
                self?.refreshStale()
            }
        }
    }
}

extension TranscriptRow {
    /// The first item the row shows: a prompt for its date, a turn's work its first call.
    var firstItemID: String? {
        switch self {
        case .item(let item): item.id
        case .toolGroup(let calls, _): calls.first?.id
        case .turnWork(_, let rows, _): rows.first?.firstItemID
        case .turnEdits(let edits): edits.promptID
        case .dateSeparator(let promptID, _): promptID
        }
    }
}
