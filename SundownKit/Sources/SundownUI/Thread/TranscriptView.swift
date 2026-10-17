import SwiftUI
import SundownKit
import TetherProtocol

/// The scrolling transcript: the scroll state, over the rows in `TranscriptContent`. The two are
/// separate views because the scroll position changes on every frame of a resize or a sidebar
/// animation, and with the rows in this body each of those frames rebuilt the whole list.
struct TranscriptView: View {
    let thread: ThreadModel
    var connection: HostConnection?
    /// Room after the end for the controls floating over it (`ThreadView`'s bottom bar).
    var bottomRoom: CGFloat = 0
    @State private var position = ScrollPosition(edge: .bottom)
    /// More than a screen from the end: Jump to Latest is offered only then.
    @State private var farFromEnd = false
    /// The last row is on screen. With it, the end is in view, whatever the lazy stack's estimate of
    /// the rows not built yet says about the content's height.
    @State private var lastRowOnScreen = true
    /// The rows on screen, for Chat ▸ Previous and Next Prompt. Not observed: it changes as rows
    /// scroll in and out, and nothing is drawn from it.
    @State private var onScreen = OnScreenRows()
    /// The rows the lazy stack has built, counted as they appear and disappear: a new count for
    /// each list it builds.
    @State private var built = BuiltRows()
    /// Bumped to build the rows anew, when the lazy stack has lost them (`recoverIfCollapsed`).
    @State private var rebuilds = 0
    @Environment(\.transcriptFind) private var find
    @Environment(\.promptNavigator) private var promptNavigator
    @Environment(\.appearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.messageSendGeometry) private var sendGeometry
    @Environment(\.transcriptPlaces) private var places

    // In parts: as one chain, the preview canvas couldn't type-check it in time.
    var body: some View {
        observingScroll(reacting(scrollView))
        // Back from another tab: where the reader was, rather than the end.
        .task {
            guard let id = places?.rows.removeValue(forKey: thread.id) else { return }
            await go(to: id)
        }
        .onDisappear {
            guard let places else { return }
            places.rows[thread.id] = onScreen.atEnd ? nil : onScreen.topRow
        }
        #if DEBUG
        .modifier(ScrollTrace(thread: thread, visible: onScreen))
        .modifier(BlankSampler(thread: thread))
        .onReceive(NotificationCenter.default.publisher(for: .stressScroll), perform: stressScroll)
        #endif
        // Loading, in the middle of the page above the bottom bar rather than a row at the top.
        .overlay { TranscriptLoading(thread: thread, connection: connection).padding(.bottom, bottomRoom) }
        .overlay(alignment: .bottom) { jumpToLatest }
    }

    private var scrollView: some View {
        ScrollView {
            TranscriptContent(thread: thread, connection: connection, position: $position, bottomRoom: bottomRoom)
                .environment(\.builtRows, built)
                // A different Tool Calls folding is a different list of rows, made new: the lazy
                // stack kept the rows it had built for the old one, and once the content had shrunk
                // to the new one's height they lay outside what it showed, so the transcript stayed
                // blank until the reader scrolled. So is a list the lazy stack lost.
                .id(RowsIdentity(folding: appearance.toolCalls.folding, rebuilds: rebuilds))
        }
        .accessibilityLabel("Transcript")
        .defaultScrollAnchor(.bottom)
        // Bottom-aligned short content pushed the top edge effect down the window.
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition($position)
    }

    /// What brings the reader somewhere: opening, sending, Find, Previous and Next Prompt, a fold.
    private func reacting(_ content: some View) -> some View {
        content
            // Shown again (back from Tasks or Diff) on a chat already loaded: at its end, unless the
            // reader had scrolled up, whose place the `task` below goes back to.
            .onAppear { if thread.historyLoaded, places?.rows[thread.id] == nil { scrollToEnd() } }
            // A newly opened chat starts at its latest message.
            .onChange(of: thread.historyLoaded) {
                guard thread.historyLoaded else { return }
                scrollToEnd()
            }
            // Sending from this window goes back to the end, where the prompt is about to land.
            .onChange(of: sendGeometry?.sends) { jumpToEnd() }
            // Find Next and Previous bring the match into view.
            .onChange(of: find?.step) {
                guard let id = find?.current else { return }
                onScreen.lastPrompt = nil
                withAnimation(motion) { position.scrollTo(id: id, anchor: .center) }
            }
            // Chat ▸ Previous and Next Prompt, from where the reader is.
            .onChange(of: promptNavigator?.step) { goToPrompt() }
            // The rows the reader was looking at can be folded into others: a different Tool Calls
            // folding, or a turn ending under Worked For. Back to the row that holds them now.
            .onChange(of: appearance.toolCalls.folding) { keepPlace(rebuilt: true) }
            .onChange(of: thread.isRunning) { keepPlace(rebuilt: false) }
    }

    /// Where the reader is, from the scroll view.
    private func observingScroll(_ content: some View) -> some View {
        content
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                onScreen.ids = Set(ids)
                let rows = thread.rows(appearance.toolCalls.folding)
                let showing = rows.last.map { onScreen.ids.contains($0.id) } ?? true
                if showing != lastRowOnScreen { lastRowOnScreen = showing }
                // Mid-resize the rows are where the lazy stack guessed: the place is the one before it.
                if !onScreen.resizing {
                    let top = rows.first { onScreen.ids.contains($0.id) }
                    onScreen.topRow = top?.id
                    onScreen.topItem = top?.firstItemID
                }
                if ids.isEmpty, !rows.isEmpty, thread.historyLoaded { checkShowingNothing("no row on screen") }
            }
            // Scrolling for themselves, the reader's place is where they scroll to, not the prompt
            // Previous or Next last went to.
            .onScrollPhaseChange { _, new in
                onScreen.phase = new
                if new == .interacting {
                    onScreen.lastPrompt = nil
                    onScreen.settling &+= 1
                }
                // Scrolling didn't always bring back rows the lazy stack had lost.
                if new == .idle { recoverIfCollapsed("after scrolling") }
            }
            .onScrollGeometryChange(for: ScrollPlace.self) { g in
                // From what's visible: the offset and container count the toolbar's inset, so at the
                // end they said 52 pt short of it, and the reader was never at the end.
                let toEnd = g.contentSize.height - g.visibleRect.maxY
                let far = toEnd > g.containerSize.height
                // The whole transcript within the container less its insets, so never while far
                // from the end.
                let room = g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom
                return ScrollPlace(far: far, atEnd: toEnd < 24,
                                   pastContent: g.contentSize.height > 0 && g.visibleRect.minY >= g.contentSize.height,
                                   fits: !far && g.contentSize.height <= room)
            } action: { _, place in
                if farFromEnd != place.far { farFromEnd = place.far }
                if !onScreen.resizing { onScreen.atEnd = place.atEnd }
                onScreen.fits = place.fits
                if place.pastContent { checkShowingNothing("scrolled past the end of the content") }
            }
            // A new width lays every row's text out again, and the lazy stack places what it hasn't
            // built at a guess: snapping a window back and forth (⌃⌥← and →) left the rows it had
            // built outside the window, which stayed blank until the next layout, while the
            // visibility callback still listed rows on screen (2026-10-13).
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width.rounded() } action: { old, new in
                if old > 0, old != new { resized() }
            }
    }

    /// Jump to Latest, while the reader is more than a screen from the end and the last row is off it.
    private var jumpToLatest: some View {
            ZStack {
                if farFromEnd, !lastRowOnScreen {
                    Button("Jump to Latest", systemImage: "arrow.down") { jumpToEnd() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Jump to Latest")
                    // Never the key view: with keyboard navigation on, a click focused it, and as it
                    // went AppKit handed focus to the transcript's first built row, which the scroll
                    // view then kept in sight, away from the end, and which ⌘F's field couldn't take
                    // the keyboard back from (CI, 2026-10-17). VoiceOver still presses it.
                    .focusable(false)
                    .padding(.bottom, 8)
                    .transition(.moving(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
                }
            }
            // Scoped to the button so the transcript's own layout changes don't animate.
            .animation(.snappy, value: farFromEnd && !lastRowOnScreen)
            // Above the bottom bar, outside the button's transition: inside it, the button slid in
            // from the bar's height below and was still on its way when clicked.
            .padding(.bottom, bottomRoom)
    }

    #if DEBUG
    /// Debug ▸ Stress's scrolls.
    private func stressScroll(_ note: Notification) {
        if let y = note.userInfo?["y"] as? CGFloat { position.scrollTo(y: y) }
        else if note.userInfo?["edge"] as? String == "top" { position.scrollTo(edge: .top) }
        else if note.userInfo?["edge"] as? String == "bottom" { scrollToEnd() }
        else if note.userInfo?["edge"] as? String == "edgebottom" { position.scrollTo(edge: .bottom) }
        else if note.userInfo?["edge"] as? String == "lastrow", let id = thread.rows(appearance.toolCalls.folding).last?.id { position.scrollTo(id: id, anchor: .bottom) }
    }
    #endif
}

extension TranscriptView {
    /// Which rows are on screen, and the prompt Previous or Next Prompt last went to, which the next
    /// press goes on from until the reader scrolls.
    final class OnScreenRows {
        var ids: Set<String> = []
        var lastPrompt: String?
        var phase: ScrollPhase = .idle
        /// Scrolled to the end (rows under the bottom bar count as on screen, so this is the
        /// geometry's word, not the last row's visibility).
        var atEnd = true
        /// The topmost row on screen and the first item it holds.
        var topRow: String?
        var topItem: String?
        /// A check for an empty screen already waiting.
        var checking = false
        /// Counts requests to go to the end; a new one, or the reader scrolling, ends the last.
        var settling = 0
        /// The whole transcript fits on screen: there's no end to go to.
        var fits = true
        /// The width is changing: `atEnd` and `topRow` keep what they were before it began.
        var resizing = false
        var resizes = 0
    }

    /// The animation for a scroll the reader asked for: none under Reduce Motion.
    private var motion: Animation? { reduceMotion ? nil : .default }

    /// To the end for the reader (sending, Jump to Latest, Next Prompt past the last): the prompt
    /// Previous and Next last went to is forgotten.
    private func jumpToEnd() {
        onScreen.lastPrompt = nil
        withAnimation(motion) { scrollToEnd() }
    }

    /// Back to where the reader was: the end, or the row that was at the top.
    private func returnToPlace() async {
        if onScreen.atEnd {
            scrollToEnd()
        } else if let top = onScreen.topRow {
            await go(to: top)
        }
    }

    /// Once the width has stopped changing, back to where the reader was before: the end, or the
    /// row that was at the top. Going to a row by its id has the lazy stack build the rows there.
    private func resized() {
        onScreen.resizing = true
        onScreen.resizes &+= 1
        let resize = onScreen.resizes
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard onScreen.resizes == resize else { return }
            onScreen.resizing = false
            await returnToPlace()
            recoverIfCollapsed("after a resize")
        }
    }

    /// The lazy stack can lose its rows altogether after rapid resizes: none built, its content
    /// height shrinking toward nothing, and neither a scroll from code nor the reader's own brought
    /// them back (2026-10-13). Given a moment to build them, a chat with rows and none built is
    /// built anew, and the reader taken back to where they were.
    private func recoverIfCollapsed(_ why: String) {
        let count = built
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard count === built, built.count == 0, thread.historyLoaded, onScreen.phase == .idle,
                  !thread.rows(appearance.toolCalls.folding).isEmpty else { return }
            Signposts.transcriptLog.error("Transcript had no rows built (\(why, privacy: .public)): built them again.")
            built = BuiltRows()
            rebuilds &+= 1
            try? await Task.sleep(for: .milliseconds(50))
            await returnToPlace()
        }
    }

    /// Scrolled up: back to the topmost row that was on screen, or, if it has been folded into
    /// another, the row that holds its first item. `rebuilt`: the rows were made anew (a different
    /// folding is a new list), so even a row still there has to be gone back to; at the end, that's
    /// the end: left to the bottom anchor, a new list of very different height left the reader a
    /// screen or more above it (Every Call from Summarized), and the next folding then kept that place.
    private func keepPlace(rebuilt: Bool) {
        if onScreen.atEnd {
            if rebuilt { scrollToEnd() }
            return
        }
        guard let topRow = onScreen.topRow, let item = onScreen.topItem else { return }
        let rows = thread.rows(appearance.toolCalls.folding)
        let still = rows.contains { $0.id == topRow }
        guard rebuilt || !still, let now = still ? topRow : rows.first(where: { $0.holds(itemID: item) })?.id else { return }
        Task { await go(to: now) }
    }

    /// Brings a row to the top once the lazy stack has the rows (a frame or two after they change),
    /// and again if it isn't on screen after that: scrolled to while rows above it were still at the
    /// stack's estimate, a row can be missed.
    private func go(to id: String) async {
        // Ends a scroll to the end still settling, which would take the reader back down.
        onScreen.settling &+= 1
        try? await Task.sleep(for: .milliseconds(50))
        position.scrollTo(id: id, anchor: .top)
        try? await Task.sleep(for: .milliseconds(250))
        guard !onScreen.ids.contains(id), onScreen.phase == .idle else { return }
        position.scrollTo(id: id, anchor: .top)
    }

    /// What the scroll geometry says that the transcript acts on: whether the end is more than a
    /// screen away, and whether the view has been left below everything it holds.
    struct ScrollPlace: Equatable {
        let far: Bool
        let atEnd: Bool
        let pastContent: Bool
        let fits: Bool
    }

    /// The chat has rows but none is on screen: the view was left past the content, as when a
    /// reload or a folding change shrank the list under the reader. Given a moment (a lazy stack
    /// builds the rows it scrolls to a frame or two later) and not while the reader scrolls, it
    /// goes back to the end and says what happened in the log.
    private func checkShowingNothing(_ why: String) {
        guard !onScreen.checking else { return }
        onScreen.checking = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            onScreen.checking = false
            let rows = thread.rows(appearance.toolCalls.folding)
            guard onScreen.ids.isEmpty || built.count == 0, !rows.isEmpty, thread.historyLoaded, onScreen.phase == .idle else { return }
            let reshape = thread.lastReshape.map { "\($0.what), \(Int(-$0.at.timeIntervalSinceNow)) s before" } ?? "none"
            Signposts.transcriptLog.error("""
                Transcript showed nothing (\(why, privacy: .public)): \(rows.count) rows, \(thread.items.count) items, \
                running \(thread.isRunning), last change to the items: \(reshape, privacy: .public). Went to the end.
                """)
            scrollToEnd()
        }
    }

    /// Brings the prompt before or after the reader's place to the top; past the last one, Next goes
    /// to the end. Before the first prompt
    /// held, Previous loads older pages until one has a prompt: only the latest page is loaded when
    /// a chat opens, and Previous stopped there.
    private func goToPrompt() {
        guard let navigator = promptNavigator else { return }
        let direction = navigator.direction
        if let id = promptTarget(direction) {
            show(prompt: id)
        } else if direction == .next {
            jumpToEnd()
        } else if thread.hasMoreHistory, let connection {
            Task {
                // Page by page until one has a prompt; not past a page that fails, or a host that's down.
                var waits = 0
                pages: while promptTarget(.previous) == nil, thread.hasMoreHistory, waits < 50 {
                    switch await connection.loadOlderHistory(thread) {
                    case .loaded: continue
                    case .busy:
                        // The spinner at the top is loading that page; wait for it.
                        waits += 1
                        try? await Task.sleep(for: .milliseconds(100))
                    case .failed, .unavailable, .complete: break pages
                    }
                }
                // Once the pages' rows exist.
                try? await Task.sleep(for: .milliseconds(50))
                if let id = promptTarget(.previous) { show(prompt: id) }
            }
        }
    }

    /// The whole transcript is on screen, so there's no end to go to.
    private var fitsOnScreen: Bool { onScreen.fits && !onScreen.ids.isEmpty }

    /// To the end of the transcript, in three steps, until the reader scrolls for themselves:
    /// - its end row, by id, not the bottom edge. The edge is the lazy stack's estimate of the rows
    ///   it hasn't built, which for replies from a line to thousands of points tall was far off: it
    ///   put the reader past every row it had built, and the transcript stayed blank until they
    ///   scrolled, for minutes (2026-10-09). A row asked for by id is built and placed where it is.
    /// - the end row again, twice, as the rows near it are built: a stack already stuck past its
    ///   rows (a chat opening, or shown again from Tasks) got out only that way. It was the last
    ///   message's row while the end row was a point tall; holding the room under the bottom bar,
    ///   the end row is a row's height of its own, and the last row's bottom is that far above the
    ///   end, so going to it put the last row under the bar and the next step took it back up.
    /// - the bottom edge, once the rows there are built and the edge is where they are: a position
    ///   held by a row's id keeps that row still, so streamed text grew below the window; held by
    ///   the edge, it follows the end.

    private func scrollToEnd() {
        // A transcript that fits sits at the top (the alignment anchor), and has no end to go to:
        // going to a row's bottom there put it a toolbar's height too low, and the alignment took it
        // back, each step, so a chat switched to jumped up and down for a moment (2026-10-16).
        // Only while rows are on screen: a transcript left blank (a reload under a scrolled reader)
        // could measure as fitting for a moment, and going nowhere left it blank for seconds.
        if !fitsOnScreen { position.scrollTo(id: TranscriptContent.endID, anchor: .bottom) }
        onScreen.settling &+= 1
        let request = onScreen.settling
        Task {
            for step in 0..<3 {
                try? await Task.sleep(for: .milliseconds(step == 0 ? 60 : 120))
                guard onScreen.settling == request else { return }
                if fitsOnScreen { continue }
                position.scrollTo(id: TranscriptContent.endID, anchor: .bottom)
                if step == 2 { position.scrollTo(edge: .bottom) }
            }
        }
    }

    private func promptTarget(_ direction: PromptNavigation.Direction) -> String? {
        PromptNavigation.target(direction, rows: thread.rows(appearance.toolCalls.folding),
                                visible: onScreen.ids, lastTarget: onScreen.lastPrompt)
    }

    private func show(prompt id: String) {
        onScreen.lastPrompt = id
        withAnimation(motion) { position.scrollTo(id: id, anchor: .top) }
    }
}

/// The rows. Only this view and the rows read `thread.rows`; everything that is not a row is its
/// own view, so a connection or turn change doesn't invalidate the whole list.
private struct TranscriptContent: View {
    static let endID = "transcript-end"
    let thread: ThreadModel
    let connection: HostConnection?
    /// For the older-history row, which keeps the reader's place as a page goes in.
    @Binding var position: ScrollPosition
    /// Room after the end, under the controls floating over it.
    var bottomRoom: CGFloat = 0
    @Environment(\.appearance) private var appearance
    @State private var turnHover = TurnHover()

    var body: some View {
        let folding = appearance.toolCalls.folding
        let rows = thread.rows(folding)
        let places = TurnPlaces(rows, prompts: thread.prompts(folding), running: thread.isRunning)
        LazyVStack(alignment: .leading, spacing: 14) {
            if !thread.historyLoaded {
                TranscriptUnavailable(thread: thread, connection: connection)
            }
            if thread.historyLoaded, thread.hasMoreHistory {
                OlderHistoryTrigger(thread: thread, connection: connection, position: $position)
            }
            // One plain view per row, identified by the ForEach alone: an `.id()` here adds a
            // node to every row, and the lazy stack walks every row on each layout pass.
            ForEach(rows, id: \.id) { row in
                TranscriptRowView(row: row, thread: thread, place: place(of: row, in: places))
            }
            // The end, which going to the latest scrolls to: always there, and never empty — a row
            // with no height is no place to scroll to: the lazy stack left the transcript blank
            // (2026-10-09). Leading, as Claude's column is: centered, the Thinking line sat mid-column.
            // It holds the room under the controls, so going to the end leaves the last row above them.
            VStack(alignment: .leading, spacing: 0) { TranscriptTail(thread: thread) }
                .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
                .padding(.bottom, bottomRoom + 2)
                .id(Self.endID)
        }
        // Rows are scroll targets by their ids: Previous Prompt and Find scroll to them.
        .scrollTargetLayout()
        .environment(\.turnHover, turnHover)
        // VoiceOver's way from prompt to prompt, which reaches the ones the lazy stack hasn't built.
        // On a container element, as a rotor has to be. Made with the rows, not from them per draw.
        .accessibilityElement(children: .contain)
        .accessibilityRotor("Prompts", entries: thread.prompts(folding), entryID: \.id, entryLabel: \.label)
        // The size every row's text starts from; View ▸ Bigger and Smaller change it.
        .scaledFont(.body)
        // The bottom margin is the end row's own (its room and 2 pt), so going to the end row and
        // to the bottom edge land in the same place: with these 2 pt here, the edge, gone to last,
        // moved a chat that had just opened 2 pt more (2026-10-17).
        .padding(.top, 16)
        .readingColumn()
        // Replies parsed off the main thread before their rows ask: the first row changes as a chat
        // opens and as an older page goes in above.
        .task(id: rows.first?.id) { await MarkdownCache.prewarm(repliesToParse()) }
    }

    private func place(of row: TranscriptRow, in places: TurnPlaces) -> TurnPlace? {
        places.turns[row.id].map { TurnPlace(turn: $0, isEnd: places.ends.contains(row.id)) }
    }

    /// The top-level replies at either end of what's held: where a chat opens and the reader
    /// starts, and where an older page just went in. Not the one streaming, which changes per frame.
    private func repliesToParse() -> [String] {
        let items = thread.items
        let ends = items.count > 120 ? Array(items.prefix(60) + items.suffix(60)) : items
        return ends.compactMap { item in
            guard case .agentMessage(let m) = item, m.parentToolUseId == nil, m.id != thread.streamingReplyID else { return nil }
            return m.text
        }
    }
}

/// Asks for the previous page when it appears at the top of the transcript, one page at a time.
/// Not while the host is down, and after a failure it waits longer each time before asking again,
/// then says it couldn't, with Try Again. A page that leaves it on screen is followed by the next.
struct OlderHistoryTrigger: View {
    let thread: ThreadModel
    let connection: HostConnection?
    @Binding var position: ScrollPosition
    @State private var gaveUp: Bool
    @State private var attempt = 0
    @Environment(\.appearance) private var appearance

    init(thread: ThreadModel, connection: HostConnection?, position: Binding<ScrollPosition>, gaveUp: Bool = false) {
        self.thread = thread
        self.connection = connection
        _position = position
        _gaveUp = State(initialValue: gaveUp)
    }

    /// Back to the row the reader was on, the one holding the item that was first before the page
    /// went in: the reader was at the top, where this row asks for a page. Neither the bottom anchor
    /// nor the scroll position keeps it there: left at the top, the reader saw whatever the page
    /// began with, and this row, still on screen, asked for every page there was, one after another
    /// (macOS 27, 2026-10-09). Done as the page goes in, before the transcript is laid out, so no
    /// frame shows the wrong rows. Found by item, since the rows folded again: a run of calls at
    /// the old top may have joined the page's.
    private func keepPlace(_ boundary: String?) {
        guard let boundary,
              let row = thread.rows(appearance.toolCalls.folding).first(where: { $0.holds(itemID: boundary) })
        else { return }
        position.scrollTo(id: row.id, anchor: .top)
    }

    /// What the asking depends on: a change of either starts it over.
    private struct Asking: Equatable {
        let connected: Bool
        let attempt: Int
    }

    var body: some View {
        let connected = connection?.state == .connected
        VStack {
            if gaveUp {
                HStack {
                    Label("Couldn’t Load Earlier Messages", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { attempt += 1 }
                        .buttonStyle(.link)
                }
                .font(.callout)
            } else {
                ProgressView("Loading Earlier Messages")
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // Runs while the row is on screen; leaving it cancels. `loadOlderHistory` answers `.busy`
        // for a page already in flight, so asking again doesn't duplicate it.
        .task(id: Asking(connected: connected, attempt: attempt)) {
            var failures = 0
            while connected, thread.hasMoreHistory, let connection, !Task.isCancelled {
                gaveUp = false
                let boundary = thread.items.first?.id
                switch await connection.loadOlderHistory(thread) {
                case .loaded:
                    keepPlace(boundary)
                    failures = 0
                    try? await Task.sleep(for: .milliseconds(300))
                case .busy:
                    failures = 0
                    try? await Task.sleep(for: .milliseconds(300))
                case .failed:
                    failures += 1
                    // 2, 4 and 8 s, then not until asked again.
                    guard failures <= 3 else {
                        gaveUp = !Task.isCancelled
                        return
                    }
                    try? await Task.sleep(for: .seconds(1 << failures))
                case .unavailable, .complete:
                    return
                }
            }
        }
    }
}

/// One transcript row: an item, read live from its box, or a group of finished tool calls.
/// Equatable because the lazy stack asks for a row again whenever it lays out, which is every frame
/// of a resize, and a row it can't compare is drawn again: an item's row is the same row as long as
/// it is the same item, since it reads the item's current state from its box.
struct TranscriptRowView: View, Equatable {
    let row: TranscriptRow
    let thread: ThreadModel
    /// Its turn, for the turn's one row of message actions; nil inside a turn's folded work, which
    /// takes its turn from the row around it.
    var place: TurnPlace? = nil
    @Environment(\.messageSendGeometry) private var sendGeometry
    @Environment(\.turnHover) private var turnHover
    @Environment(\.builtRows) private var builtRows

    nonisolated static func == (a: Self, b: Self) -> Bool {
        guard a.thread === b.thread, a.place == b.place else { return false }
        switch (a.row, b.row) {
        case (.item(let x), .item(let y)): return x.id == y.id
        case (.toolGroup(let x, let xe), .toolGroup(let y, let ye)): return x == y && xe == ye
        // The same turn's work, as long as it holds the same rows; each item reads its own box.
        case (.turnWork(let x, let xs, let xd), .turnWork(let y, let ys, let yd)):
            return x == y && xd == yd && xs.map(\.id) == ys.map(\.id)
        case (.turnEdits(let x), .turnEdits(let y)): return x == y
        case (.dateSeparator(let x, let xs), .dateSeparator(let y, let ys)): return x == y && xs == ys
        default: return false
        }
    }

    var body: some View {
        // A stack, not a Group: one view for every row, whatever it holds, so the transcript's
        // ForEach can count its rows without building them (a Group left it on SwiftUI's slow path).
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .item(let item):
                // A prompt already shown here as a chat started doesn't fade in again.
                LiveItemView(box: thread.box(for: item), thread: thread)
                    .modifier(FadesIn(isNew: thread.justStarted(item.id) && sendGeometry?.landedPrompt != item.id,
                                      pushes: item.isOwnPrompt))
            case .toolGroup(let calls, let edits): ToolCallGroupView(calls: calls, edits: edits, thread: thread, rowID: row.id)
            case .turnWork(let id, let rows, let durationMs): TurnWorkView(rows: rows, durationMs: durationMs, thread: thread, rowID: id)
            case .turnEdits(let edits): TurnEditsView(edits: edits, cwd: thread.cwd)
            case .dateSeparator(_, let ms): DateSeparatorView(ms: ms)
            }
        }
        .modifier(FindHighlight(id: row.id))
        #if DEBUG
        .modifier(TraceRowFrame(id: row.id))
        #endif
        .transformEnvironment(\.turnPlace) { if let place { $0 = place } }
        // Anywhere in a turn shows its actions, after its last reply.
        .onHover { inside in if let place { turnHover?.pointer(inside, turn: place.turn) } }
        // Built and let go by the lazy stack.
        .onAppear { builtRows?.count += 1 }
        .onDisappear { builtRows?.count -= 1 }
    }
}

/// A row for an item that just started fades in rather than popping in. Opacity only, so it suits
/// Reduce Motion as it is.
/// The person's own just-sent prompt pushes in from below instead, on a spring, driven from
/// `onAppear` like the fade: the lazy stack builds the row as it appears, so an insertion
/// `.transition` has no transaction to run in. Reduce Motion keeps the fade.
private struct FadesIn: ViewModifier {
    @State private var shown: Bool
    private let pushes: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isNew: Bool, pushes: Bool) {
        _shown = State(initialValue: !isNew)
        self.pushes = pushes
    }

    func body(content: Content) -> some View {
        let push = pushes && !reduceMotion
        let below = push && !shown
        content
            .visualEffect { view, proxy in
                view.offset(y: below ? proxy.size.height : 0)
            }
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                if push {
                    withAnimation(TranscriptMotion.spring) { shown = true }
                } else {
                    withAnimation(.easeOut(duration: MarkdownTheme.fadeDuration)) { shown = true }
                }
            }
    }
}

private extension Item {
    /// A prompt the person typed here: not synthetic, not a subagent's.
    var isOwnPrompt: Bool {
        if case .userMessage(let m) = self { return m.synthetic != true && m.parentToolUseId == nil }
        return false
    }
}


/// A row Find in Chat matched: tinted with the system's find color, strongest on the current match.
private struct FindHighlight: ViewModifier {
    let id: String
    @Environment(\.transcriptFind) private var find

    func body(content: Content) -> some View {
        let isCurrent = find?.current == id
        let isMatch = isCurrent || find?.matches.contains(id) == true
        content
            .background {
                if isMatch {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .findHighlightColor).opacity(isCurrent ? 0.2 : 0.08))
                        .padding(-6)
                }
            }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            // The words themselves too, in a matched message's text.
            .environment(\.findQuery, isMatch ? find?.query : nil)
    }
}

/// Stands in for the transcript before it arrives; a failure says so and offers a way out. While
/// the host isn't connected it waits as it does for the history, the spinner alone: the status card
/// in the composer's place says why, once. (It was nothing at all, and a chat opened while the host
/// was reconnecting was a blank window.)
/// Its own view so `connection.state` and `thread.lastError` are not read in the transcript's body.
struct TranscriptUnavailable: View {
    let thread: ThreadModel
    var connection: HostConnection?

    /// Why the chat couldn't be opened, once its host is there to try again; until then it's loading.
    static func failure(_ thread: ThreadModel, _ connection: HostConnection?) -> String? {
        guard let error = thread.lastError, connection?.state == .connected || connection == nil else { return nil }
        return error
    }

    var body: some View {
        // Loading is `TranscriptLoading`, over the transcript's middle.
        if let error = Self.failure(thread, connection) {
            ContentUnavailableView {
                Label("Couldn\u{2019}t Open This Chat", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                if let connection { Button("Try Again") { Task { await connection.open(thread) } } }
            }
            .padding(.vertical, 40)
        }
    }
}

/// The spinner while a chat's history loads, centred where the transcript will be.
struct TranscriptLoading: View {
    let thread: ThreadModel
    var connection: HostConnection?

    var body: some View {
        if !thread.historyLoaded, TranscriptUnavailable.failure(thread, connection) == nil {
            ProgressView("Loading Chat")
                .labelsHidden()
                .accessibilityIdentifier("transcript.loading")
        }
    }
}

/// The end of the transcript: the wait before a turn has anything to show, and why the last turn
/// stopped short. Its own view so `isThinking` and `turns` are read here rather than beside the rows.
struct TranscriptTail: View {
    let thread: ThreadModel
    @Environment(\.appearance) private var appearance

    /// Whether the turn's run of calls is the last row, and says Thinking itself.
    private var runSaysIt: Bool {
        guard appearance.toolCalls.folding != .everyCall, case .toolCall(let call)? = thread.lastShownItem else { return false }
        return call.kind != .todoWrite && call.kind != .subagent
    }

    /// What the wait before anything shows is: starting the session (New Chat's stand-in for a chat
    /// the host hasn't answered for yet), compacting, or thinking. One line whose words change in place.
    private var activity: String? {
        if thread.isStarting { return "Starting session" }
        // Compacting says so where Thinking would, not in a card under the transcript.
        if thread.activity == "compacting" { return "Compacting conversation" }
        if thread.isThinking, !runSaysIt { return "Thinking" }
        return nil
    }

    /// The last row says what's happening now (a call running, or a run of calls saying Thinking),
    /// and so has the running tasks' count beside it.
    private var rowIsCurrent: Bool {
        guard case .toolCall(let call)? = thread.lastShownItem else { return false }
        if call.status == .running || call.status == .pending { return !call.isWorkflow }
        return thread.isThinking && runSaysIt
    }

    var body: some View {
        // The chat's background work as one count beside what's happening now (this line, or the
        // row saying it), or alone once nothing is, opening Tasks: not a line per agent or
        // command as each one ends.
        if let activity {
            HStack(spacing: 8) {
                ActivityLine(text: activity)
                RunningTasksCount(thread: thread)
            }
            .transcriptLine()
        } else if thread.hasBackgroundWork, !rowIsCurrent {
            RunningTasksLink(count: thread.backgroundTaskCount)
                .transcriptLine()
        }
        // A turn that finished normally says nothing; its cost and time are in the Session pane.
        if let turn = thread.turns.last, turn.status == .interrupted || turn.status == .failed {
            TurnOutcome(turn: turn)
        }
    }
}

/// "· 3 running tasks", after what's happening now, while any of the chat's tasks run.
struct RunningTasksCount: View {
    let thread: ThreadModel

    var body: some View {
        if thread.hasBackgroundWork {
            HStack(spacing: 8) {
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                RunningTasksLink(count: thread.backgroundTaskCount)
            }
        }
    }
}

/// How many of the chat's tasks are still running, as a link to them in the Tasks tab.
struct RunningTasksLink: View {
    let count: Int
    @Environment(\.showTasks) private var showTasks

    var body: some View {
        Button { showTasks() } label: {
            Text("^[\(count) running task](inflect: true)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .fontWeight(.medium)
        .help("Show Tasks")
        .accessibilityHint("Shows them in the Tasks tab")
    }
}

/// A shimmering line for what the turn is doing while it has nothing else to show.
struct ActivityLine: View {
    let text: String

    var body: some View {
        ActivityLabel(text: text, live: true)
            .transcriptLine()
            // The model's changes carry no animation, so the transition brings its own.
            .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
}

struct TurnOutcome: View {
    let status: TurnStatus
    let error: String?

    /// What the line says.
    var words: String { status == .interrupted ? "Interrupted" : error ?? "The turn failed" }

    var body: some View {
        Group {
            if status == .interrupted {
                Label(words, systemImage: "stop.circle").foregroundStyle(.tertiary)
            } else {
                Label(words, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .scaledFont(.caption)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

extension TurnOutcome {
    /// Why the turn stopped, from its result's errors: never the result's subtype, a wire value
    /// such as `error_during_execution` (#50).
    init(turn: Turn) {
        self.init(status: turn.status, error: turn.result?.errors?.first)
    }
}

#if DEBUG
#Preview("TranscriptView") {
    TranscriptView(thread: .sampleToolCalls())
        .frame(width: 900, height: 760)
}

#Preview("TranscriptView (long settled turn)") {
    var items: [Item] = [.sampleUserMessage("Check each part of the renderer.", secondsAgo: 100)]
    for index in 0..<40 {
        let ago = Double(90 - index * 2)
        items.append(.sampleToolCall(name: "Read", kind: .fileRead,
                                    input: ["file_path": .string("/tmp/Renderer\(index).swift")],
                                    status: .completed, secondsAgo: ago))
        items.append(.sampleAgentMessage("Checked renderer \(index). Continuing with the next part.", secondsAgo: ago - 1))
    }
    items.append(.sampleAgentMessage("## Finished\n\nThe renderer's checks are complete.", secondsAgo: 4))
    return TranscriptView(thread: .sample(title: "Long settled turn", items: items, turns: [.sample()]))
        .frame(width: 900, height: 760)
}

/// A /loop's wakeups and a /goal in the chat: each firing a quiet line where its turn starts, the
/// schedule's calls in plain words, the goal set, checked and met as quiet lines.
#Preview("TranscriptView (loop and goal)") {
    TranscriptView(thread: .sampleScheduledWork(finished: true))
        .frame(width: 900, height: 760)
}

/// What stands in for a transcript that couldn't be opened. A host that's down is said by the
/// status card instead ("Status card (chat not loaded)").
#Preview("TranscriptView (loading)") {
    TranscriptView(thread: .sampleUnloaded(), connection: .sample())
        .frame(width: 900, height: 420)
}

#Preview("TranscriptView (open failed)") {
    TranscriptView(thread: .sampleUnloaded(lastError: "thread/read failed: no thread with that id"),
                   connection: .sample())
        .frame(width: 900, height: 420)
}

#Preview("TurnOutcome") {
    VStack(alignment: .trailing, spacing: 12) {
        TurnOutcome(status: .failed, error: "SSH connection to deploy-01 timed out")
        TurnOutcome(status: .interrupted, error: nil)
    }
    .padding(20)
    .frame(width: 500)
}

/// Older history that couldn't be loaded after a few tries: said once, quietly, with Try Again.
#Preview("Earlier messages (couldn’t load)") {
    OlderHistoryTrigger(thread: .sampleIdleChat(), connection: nil, position: .constant(ScrollPosition()), gaveUp: true)
        .padding(20)
        .frame(width: 500)
}

#endif

/// A row's turn: which one, and whether the row is its last reply, where the actions go.
struct TurnPlace: Equatable {
    let turn: String
    let isEnd: Bool
}

/// The turn under the pointer. Only a turn's action row reads it, so moving over the transcript
/// redraws those rows and nothing else. Leaving a row waits a moment before letting go, since
/// the pointer crosses the gaps between a turn's rows.
@MainActor @Observable
final class TurnHover {
    private(set) var turn: String?
    /// The prompt under the pointer, whose own capsule shows instead of its turn's.
    private(set) var prompt: String?

    func pointer(_ inside: Bool, prompt id: String) {
        if inside { if prompt != id { prompt = id } } else if prompt == id { prompt = nil }
    }

    @ObservationIgnored private var leaving: Task<Void, Never>?

    func pointer(_ inside: Bool, turn key: String) {
        leaving?.cancel()
        if inside {
            if turn != key { turn = key }
        } else if turn == key {
            leaving = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.turn == key else { return }
                self.turn = nil
            }
        }
    }
}

/// Where the reader was in each chat a window showed, for the Chat tab to go back to: switching
/// to Tasks or Diff takes the transcript away, and made again it opened at the end. Not observed:
/// read once as the transcript appears, written as it goes.
@MainActor
final class TranscriptPlaces {
    /// The topmost row on screen, by chat; none while the reader was at the end.
    var rows: [String: String] = [:]
}

/// How many of the transcript's rows the lazy stack has built. Not observed: counted as rows appear
/// and disappear, and read only to tell whether it has lost them.
@MainActor
final class BuiltRows {
    var count = 0
}

/// The list of rows the transcript's lazy stack builds: a new one for another folding, or to
/// rebuild rows it lost.
private struct RowsIdentity: Hashable {
    let folding: TranscriptFolding
    let rebuilds: Int
}

extension EnvironmentValues {
    @Entry var builtRows: BuiltRows? = nil
    @Entry var transcriptPlaces: TranscriptPlaces? = nil
    @Entry var turnHover: TurnHover? = nil
    @Entry var turnPlace: TurnPlace? = nil
}

/// The spring a sent prompt pushes in with.
private enum TranscriptMotion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.8)
}

private extension TranscriptRow {
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
