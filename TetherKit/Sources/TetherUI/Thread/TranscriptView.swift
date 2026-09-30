import SwiftUI
import TetherKit
import TetherProtocol

/// The scrolling transcript: the scroll state, over the rows in `TranscriptContent`. The two are
/// separate views because the scroll position changes on every frame of a resize or an inspector
/// animation, and with the rows in this body each of those frames rebuilt the whole list.
struct TranscriptView: View {
    let thread: ThreadModel
    var connection: HostConnection?
    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether the reader left the transcript at its end. Only their own scrolling changes it, so a
    /// resize that briefly pushes the end off screen doesn't count as scrolling away.
    @State private var followsEnd = true
    /// The rows on screen, for Chat ▸ Previous and Next Prompt. Not observed: it changes as rows
    /// scroll in and out, and nothing is drawn from it.
    @State private var onScreen = OnScreenRows()
    /// Where the reader is, for loading older pages.
    @State private var older = OlderPages()
    @Environment(\.transcriptFind) private var find
    @Environment(\.promptNavigator) private var promptNavigator
    @Environment(\.appearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            TranscriptContent(thread: thread, connection: connection, older: older)
                // A different Tool Calls folding is a different list of rows, made new: the lazy
                // stack kept the rows it had built for the old one, and once the content had shrunk
                // to the new one's height they lay outside what it showed, so the transcript stayed
                // blank until the reader scrolled.
                .id(appearance.toolCalls.folding)
        }
        // Opens at the end and keeps it pinned through content and size changes. A transcript shorter
        // than the window sits at the top: aligned to the bottom, it was pushed down by a scroll offset
        // and the toolbar's edge effect followed its top edge down the window.
        .accessibilityLabel("Transcript")
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition($position)
        // A newly opened chat starts at its latest message.
        .onChange(of: thread.historyLoaded) {
            guard thread.historyLoaded else { return }
            followsEnd = true
            position.scrollTo(edge: .bottom)
        }
        .onScrollGeometryChange(for: Place.self, of: { Place($0) }) { keepPlace(from: $0, to: $1) }
        .onAppear { older.page = thread.pageAnchor }
        // Find Next and Previous bring the match into view; the reader has left the end to read it.
        .onChange(of: find?.step) {
            guard let id = find?.current else { return }
            onScreen.lastPrompt = nil
            older.taken = true
            followsEnd = false
            withAnimation(reduceMotion ? nil : .default) { position.scrollTo(id: id, anchor: .center) }
        }
        // Chat ▸ Previous and Next Prompt, from where the reader is.
        .onChange(of: promptNavigator?.step) { goToPrompt() }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { onScreen.ids = Set($0) }
        .onScrollPhaseChange { old, new, context in
            older.scrolling = new != .idle
            // Scrolling for themselves, the reader's place is where they scroll to, not the prompt
            // Previous or Next last went to.
            if new == .interacting {
                onScreen.lastPrompt = nil
                older.taken = false
            }
            guard new == .idle, old == .interacting || old == .decelerating else { return }
            let g = context.geometry
            followsEnd = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24
        }
        // Offered once the reader has scrolled away, not whenever the end is off screen: a resize
        // pushes it off for a frame or two, and the button flickered in and out.
        .overlay(alignment: .bottom) {
            ZStack {
                if !followsEnd {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        onScreen.lastPrompt = nil
                        followsEnd = true
                        withAnimation(reduceMotion ? nil : .default) { position.scrollTo(edge: .bottom) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Jump to Latest")
                    .padding(.bottom, 8)
                    .transition(.moving(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
                }
            }
            // Scoped to the button so the transcript's own layout changes don't animate.
            .animation(.snappy, value: followsEnd)
        }
    }
}

extension TranscriptView {
    /// Where the reader is, and how tall what they're reading is.
    struct Place: Equatable {
        let content: CGFloat
        let offset: CGFloat
        let nearTop: Bool

        init(_ g: ScrollGeometry) {
            content = g.contentSize.height
            // From the top of the content, as `scrollTo(y:)` takes it: the content offset counts
            // from under the toolbar, and moving on by it left the reader the toolbar's height out.
            offset = g.contentOffset.y + g.contentInsets.top
            nearTop = offset < g.containerSize.height * 1.5
        }
    }

    /// An older page goes in above the reader, who stays on the row they were reading. The scroll
    /// view keeps the same offset from the top, which showed the page's first rows, so once the
    /// page is laid out the reader is moved on by what it added. A frame late: SwiftUI holds a
    /// place as content goes in above only at the end, not by a row's identity (`scrollTo(id:)`,
    /// a position typed by row) or a size-change anchor, and nothing set as the page goes in reaches
    /// the frame that lays it out. `ThreadModel.pageAnchor` says a page added rows; the rows aren't
    /// read here, which would redraw this view whenever they change.
    private func keepPlace(from old: Place, to new: Place) {
        let nearTop = new.nearTop && !older.taken
        if older.nearTop != nearTop { older.nearTop = nearTop }
        guard let page = thread.pageAnchor, page != older.page, new.content > old.content else { return }
        older.page = page
        // At the end the scroll view keeps the place itself. Not told by the offset having moved:
        // the scroll for a page just before can land in the same frame as the next.
        guard !followsEnd else { return }
        position.scrollTo(point: CGPoint(x: 0, y: new.offset + new.content - old.content))
    }

    /// Which rows are on screen, and the prompt Previous or Next Prompt last went to, which the next
    /// press goes on from until the reader scrolls.
    final class OnScreenRows {
        var ids: Set<String> = []
        var lastPrompt: String?
    }

    /// Brings the prompt before or after the reader's place to the top; past the last one, Next goes
    /// to the end. The reader has left the end to read it, as with Find. Before the first prompt
    /// held, Previous loads older pages until one has a prompt: only the latest page is loaded when
    /// a chat opens, and Previous stopped there.
    private func goToPrompt() {
        guard let navigator = promptNavigator else { return }
        let direction = navigator.direction
        if let id = promptTarget(direction) {
            show(prompt: id)
        } else if direction == .next {
            onScreen.lastPrompt = nil
            followsEnd = true
            withAnimation(reduceMotion ? nil : .default) { position.scrollTo(edge: .bottom) }
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
                // Going to the prompt, not held in place as the pages go in above (`keepPlace`): that
                // scroll came after this one when a big page took a while to lay out, and undid it.
                older.page = thread.pageAnchor
                // Once the pages' rows exist.
                try? await Task.sleep(for: .milliseconds(50))
                if let id = promptTarget(.previous) { show(prompt: id) }
            }
        }
    }

    private func promptTarget(_ direction: PromptNavigation.Direction) -> String? {
        PromptNavigation.target(direction, rows: thread.rows(appearance.toolCalls.folding),
                                visible: onScreen.ids, lastTarget: onScreen.lastPrompt)
    }

    private func show(prompt id: String) {
        onScreen.lastPrompt = id
        older.taken = true
        followsEnd = false
        withAnimation(reduceMotion ? nil : .default) { position.scrollTo(id: id, anchor: .top) }
    }
}

/// The rows. Only this view and the rows read `thread.rows`; everything that is not a row is its
/// own view, so a connection or turn change doesn't invalidate the whole list.
private struct TranscriptContent: View {
    let thread: ThreadModel
    let connection: HostConnection?
    let older: OlderPages
    @Environment(\.appearance) private var appearance

    /// Keep a small settled tail measured exactly, without eagerly laying out a whole long turn.
    private static let eagerTailLimit = 8

    var body: some View {
        let folding = appearance.toolCalls.folding
        let rows = thread.rows(folding)
        // A live turn stays in one container as it grows: moving its rows across the split would
        // discard their view state. Once settled, only a bounded tail needs exact measurements.
        let turnStart = thread.prompts(folding).last.flatMap { last in rows.lastIndex { $0.id == last.id } } ?? rows.count
        let split = thread.isRunning ? turnStart : max(turnStart, rows.count - Self.eagerTailLimit)
        VStack(alignment: .leading, spacing: 14) {
            if !thread.historyLoaded || thread.hasMoreHistory || split > 0 {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !thread.historyLoaded {
                        TranscriptUnavailable(thread: thread, connection: connection)
                    }
                    if thread.historyLoaded, thread.hasMoreHistory {
                        OlderHistoryTrigger(thread: thread, connection: connection, older: older)
                    }
                    // One plain view per row, identified by the ForEach alone: an `.id()` here adds a
                    // node to every row, and the lazy stack walks every row on each layout pass.
                    ForEach(rows[..<split], id: \.id) { row in
                        TranscriptRowView(row: row, thread: thread)
                    }
                }
                // Rows are scroll targets by their ids, so an older page can keep the reader where they were.
                .scrollTargetLayout()
            }
            // The live turn, or a bounded tail of a settled turn, built in full rather than lazily. The lazy
            // stack counts a row it hasn't built at a guessed height; a row just added at the end was
            // counted that way until built, then at its own, a different total, and the scroll view's
            // anchor on the end moved the transcript by the difference, which changed which rows the
            // stack built, and so on: the transcript bounced between two places while a reply streamed.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows[split...], id: \.id) { row in
                    TranscriptRowView(row: row, thread: thread)
                }
                TranscriptTail(thread: thread)
            }
            .scrollTargetLayout()
        }
        // VoiceOver's way from prompt to prompt, which reaches the ones the lazy stack hasn't built.
        // On a container element, as a rotor has to be. Made with the rows, not from them per draw.
        .accessibilityElement(children: .contain)
        .accessibilityRotor("Prompts", entries: thread.prompts(folding), entryID: \.id, entryLabel: \.label)
        // The size every row's text starts from; View ▸ Bigger and Smaller change it.
        .scaledFont(.body)
        .padding(.vertical, 16)
        .readingColumn()
        // Replies parsed off the main thread before their rows ask: the first row changes as a chat
        // opens and as an older page goes in above.
        .task(id: rows.first?.id) { await MarkdownCache.prewarm(repliesToParse()) }
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

/// Where the reader is, as loading older pages needs it. Only the spinner that loads them observes
/// it, so nothing else redraws as the reader nears the top.
@MainActor @Observable
final class OlderPages {
    /// Within a screen and a half of the top: the page before is asked for from there, so it's
    /// usually in before the reader gets to the top.
    var nearTop = false
    /// Whether the reader is scrolling. SwiftUI ignores a scroll position set meanwhile, so the
    /// reader's place couldn't be kept: a page waits for them to stop (`settled`).
    @ObservationIgnored var scrolling = false
    /// Whether Previous Prompt or Find took the reader where they are, and they haven't scrolled
    /// since. No page is asked for meanwhile: going in, it moved what they were taken to a little,
    /// as the lazy stack measured the page's rows. Previous Prompt loads the pages it needs itself.
    @ObservationIgnored var taken = false
    /// The last page the reader was kept in place past.
    @ObservationIgnored var page: ThreadModel.PageAnchor?

    func settled() async {
        while scrolling, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

/// Asks for the previous page while the reader is near the top of the transcript, one page at a
/// time. Not while the host is down, and after a failure it waits longer each time before asking
/// again, then says it couldn't, with Try Again: every 300 ms it asked a host that couldn't answer.
/// Scrolling away from the top and back, or the host coming back, starts it over too.
private struct OlderHistoryTrigger: View {
    let thread: ThreadModel
    let connection: HostConnection?
    let older: OlderPages
    @State private var gaveUp: Bool
    @State private var attempt = 0

    init(thread: ThreadModel, connection: HostConnection?, older: OlderPages, gaveUp: Bool = false) {
        self.thread = thread
        self.connection = connection
        self.older = older
        _gaveUp = State(initialValue: gaveUp)
    }

    /// What the asking depends on: a change of any starts it over.
    private struct Asking: Equatable {
        let nearTop: Bool
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
        // A page goes in above the reader and normally takes them away from the top, which ends
        // this. One short enough to leave them near it changes nothing, so after a moment for the
        // scroll to settle the next page is asked for here.
        .task(id: Asking(nearTop: older.nearTop, connected: connected, attempt: attempt)) {
            var failures = 0
            while older.nearTop, connected, thread.hasMoreHistory, let connection, !Task.isCancelled {
                gaveUp = false
                switch await connection.loadOlderHistory(thread, whenReady: older.settled) {
                case .loaded, .busy:
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
    @Environment(\.messageSendGeometry) private var sendGeometry

    private var isSendingPrompt: Bool {
        guard case .item(.userMessage(let message)) = row else { return false }
        return sendGeometry?.activeMessageID == message.id
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        guard a.thread === b.thread else { return false }
        switch (a.row, b.row) {
        case (.item(let x), .item(let y)): return x.id == y.id
        case (.toolGroup(let x), .toolGroup(let y)): return x == y
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
                LiveItemView(box: thread.box(for: item), thread: thread)
                    .modifier(FadesIn(isNew: thread.justStarted(item.id)))
            case .toolGroup(let calls): ToolCallGroupView(calls: calls, thread: thread, rowID: row.id)
            case .turnWork(let id, let rows, let durationMs): TurnWorkView(rows: rows, durationMs: durationMs, thread: thread, rowID: id)
            case .turnEdits(let edits): TurnEditsView(edits: edits, cwd: thread.cwd)
            case .dateSeparator(_, let ms): DateSeparatorView(ms: ms)
            }
        }
        .modifier(FindHighlight(id: row.id))
        // A reply can begin immediately. Keep the moving surface above its sibling text while
        // crossing that row, then return to normal drawing order when the handoff settles.
        .zIndex(isSendingPrompt ? 1 : 0)
    }
}

/// A row for an item that just started fades in rather than popping in. Opacity only, so it suits
/// Reduce Motion as it is.
private struct FadesIn: ViewModifier {
    @State private var shown: Bool

    init(isNew: Bool) {
        _shown = State(initialValue: !isNew)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                withAnimation(.easeOut(duration: FadeInRenderer.duration)) { shown = true }
            }
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
                        .fill(Color(nsColor: .findHighlightColor).opacity(isCurrent ? 0.4 : 0.15))
                        .padding(-6)
                }
            }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Stands in for the transcript before it arrives; a failure says so and offers a way out. Nothing
/// while the host isn't connected: the status card in the composer's place says that, once.
/// Its own view so `connection.state` and `thread.lastError` are not read in the transcript's body.
struct TranscriptUnavailable: View {
    let thread: ThreadModel
    var connection: HostConnection?

    var body: some View {
        if let connection, connection.state != .connected {
            EmptyView()
        } else if let error = thread.lastError {
            TranscriptPlaceholder("Couldn\u{2019}t Open This Chat", symbol: "exclamationmark.triangle", detail: error) {
                if let connection { Button("Try Again") { Task { await connection.open(thread) } } }
            }
        } else {
            ProgressView("Loading Chat")
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(40)
        }
    }
}

/// The transcript's stand-in when there is nothing to show: a reason and a way forward.
struct TranscriptPlaceholder<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, symbol: String, detail: String?, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let detail { Text(detail).textSelection(.enabled) }
        } actions: {
            actions
        }
        .padding(.vertical, 40)
    }
}

/// The end of the transcript: the wait before a turn has anything to show, and why the last turn
/// stopped short. Its own view so `isThinking` and `turns` are read here rather than beside the rows.
/// A `Group` rather than a stack, so that with neither of them the enclosing spacing collapses too.
struct TranscriptTail: View {
    let thread: ThreadModel

    var body: some View {
        Group {
            if thread.isThinking { ThinkingLine() }
            // A turn that finished normally says nothing; its cost and time are in the Session pane.
            if let turn = thread.turns.last, turn.status == .interrupted || turn.status == .failed {
                TurnOutcome(status: turn.status, error: turn.result?.errors?.first)
            }
        }
    }
}

/// Marks the wait before a turn has anything to show. From the thread's status, so it works
/// with thinking off or redacted. Its dots pulse, but not while the Mac saves energy.
struct ThinkingLine: View {
    @Environment(\.reducesEffects) private var reducesEffects
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label("Thinking…", systemImage: "ellipsis")
            .symbolEffect(.variableColor.iterative, options: .repeating.speed(1.8), isActive: !reducesEffects && !reduceMotion)
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
            // The model's changes carry no animation, so the transition brings its own.
            .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
}

struct TurnOutcome: View {
    let status: TurnStatus
    let error: String?

    var body: some View {
        Group {
            if status == .interrupted {
                Label("Interrupted", systemImage: "stop.circle").foregroundStyle(.tertiary)
            } else {
                Label(error ?? "The turn failed", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .scaledFont(.caption)
        .frame(maxWidth: .infinity, alignment: .trailing)
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

/// What stands in for a transcript that couldn't be opened. A host that's down is said by the
/// status card instead ("Status card (chat not loaded)").
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
    OlderHistoryTrigger(thread: .sampleIdleChat(), connection: nil, older: OlderPages(), gaveUp: true)
        .padding(20)
        .frame(width: 500)
}

#endif
