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
    /// More than a screen from the end: Jump to Latest is offered only then.
    @State private var farFromEnd = false
    /// The rows on screen, for Chat ▸ Previous and Next Prompt. Not observed: it changes as rows
    /// scroll in and out, and nothing is drawn from it.
    @State private var onScreen = OnScreenRows()
    @Environment(\.transcriptFind) private var find
    @Environment(\.promptNavigator) private var promptNavigator
    @Environment(\.appearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.messageSendGeometry) private var sendGeometry

    var body: some View {
        ScrollView {
            TranscriptContent(thread: thread, connection: connection)
                // A different Tool Calls folding is a different list of rows, made new: the lazy
                // stack kept the rows it had built for the old one, and once the content had shrunk
                // to the new one's height they lay outside what it showed, so the transcript stayed
                // blank until the reader scrolled.
                .id(appearance.toolCalls.folding)
        }
        .accessibilityLabel("Transcript")
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        // A newly opened chat starts at its latest message.
        .onChange(of: thread.historyLoaded) {
            guard thread.historyLoaded else { return }
            position.scrollTo(edge: .bottom)
        }
        // Sending from this window goes back to the end, where the prompt is about to land.
        .onChange(of: sendGeometry?.sends) {
            onScreen.lastPrompt = nil
            withAnimation(reduceMotion ? nil : .default) { position.scrollTo(edge: .bottom) }
        }
        // Find Next and Previous bring the match into view.
        .onChange(of: find?.step) {
            guard let id = find?.current else { return }
            onScreen.lastPrompt = nil
            withAnimation(reduceMotion ? nil : .default) { position.scrollTo(id: id, anchor: .center) }
        }
        // Chat ▸ Previous and Next Prompt, from where the reader is.
        .onChange(of: promptNavigator?.step) { goToPrompt() }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { onScreen.ids = Set($0) }
        // Scrolling for themselves, the reader's place is where they scroll to, not the prompt
        // Previous or Next last went to.
        .onScrollPhaseChange { _, new in
            if new == .interacting { onScreen.lastPrompt = nil }
        }
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentSize.height - (g.contentOffset.y + g.containerSize.height) > g.containerSize.height
        } action: { _, far in
            farFromEnd = far
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if farFromEnd {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        onScreen.lastPrompt = nil
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
            .animation(.snappy, value: farFromEnd)
        }
    }
}

extension TranscriptView {
    /// Which rows are on screen, and the prompt Previous or Next Prompt last went to, which the next
    /// press goes on from until the reader scrolls.
    final class OnScreenRows {
        var ids: Set<String> = []
        var lastPrompt: String?
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
            onScreen.lastPrompt = nil
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
        withAnimation(reduceMotion ? nil : .default) { position.scrollTo(id: id, anchor: .top) }
    }
}

/// The rows. Only this view and the rows read `thread.rows`; everything that is not a row is its
/// own view, so a connection or turn change doesn't invalidate the whole list.
private struct TranscriptContent: View {
    let thread: ThreadModel
    let connection: HostConnection?
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
                OlderHistoryTrigger(thread: thread, connection: connection)
            }
            // One plain view per row, identified by the ForEach alone: an `.id()` here adds a
            // node to every row, and the lazy stack walks every row on each layout pass.
            ForEach(rows, id: \.id) { row in
                TranscriptRowView(row: row, thread: thread, place: place(of: row, in: places))
            }
            TranscriptTail(thread: thread)
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
        .padding(.vertical, 16)
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
    @State private var gaveUp: Bool
    @State private var attempt = 0

    init(thread: ThreadModel, connection: HostConnection?, gaveUp: Bool = false) {
        self.thread = thread
        self.connection = connection
        _gaveUp = State(initialValue: gaveUp)
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
                switch await connection.loadOlderHistory(thread) {
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
    /// Its turn, for the turn's one row of message actions; nil inside a turn's folded work, which
    /// takes its turn from the row around it.
    var place: TurnPlace? = nil
    @Environment(\.messageSendGeometry) private var sendGeometry
    @Environment(\.turnHover) private var turnHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        guard a.thread === b.thread, a.place == b.place else { return false }
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
                // A prompt already shown here as a chat started doesn't fade in again.
                LiveItemView(box: thread.box(for: item), thread: thread)
                    .modifier(FadesIn(isNew: thread.justStarted(item.id) && sendGeometry?.landedPrompt != item.id))
            case .toolGroup(let calls): ToolCallGroupView(calls: calls, thread: thread, rowID: row.id)
            case .turnWork(let id, let rows, let durationMs): TurnWorkView(rows: rows, durationMs: durationMs, thread: thread, rowID: id)
            case .turnEdits(let edits): TurnEditsView(edits: edits, cwd: thread.cwd)
            case .dateSeparator(_, let ms): DateSeparatorView(ms: ms)
            }
        }
        .modifier(FindHighlight(id: row.id))
        .transformEnvironment(\.turnPlace) { if let place { $0 = place } }
        // Anywhere in a turn shows its actions, after its last reply.
        .onHover { inside in if let place { turnHover?.pointer(inside, turn: place.turn) } }
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
    @Environment(\.appearance) private var appearance

    /// Whether the turn's run of calls is the last row, and says Thinking itself.
    private var runSaysIt: Bool {
        guard appearance.toolCalls.folding != .everyCall, case .toolCall(let call)? = thread.lastShownItem else { return false }
        return call.kind != .todoWrite && call.kind != .subagent
    }

    /// What the wait before anything shows is: starting the session (New Chat's stand-in for a chat
    /// the host hasn't answered for yet), compacting, or thinking. One line whose words change in place.
    private var activity: String? {
        if thread.isStarting { return "Starting Session" }
        // Compacting says so where Thinking would, not in a card under the transcript.
        if thread.activity == "compacting" { return "Compacting Conversation" }
        if thread.isThinking, !runSaysIt { return "Thinking" }
        return nil
    }

    var body: some View {
        Group {
            if let activity {
                ActivityLine(text: activity)
            }
            // A turn that finished normally says nothing; its cost and time are in the Session pane.
            if let turn = thread.turns.last, turn.status == .interrupted || turn.status == .failed {
                TurnOutcome(status: turn.status, error: turn.result?.errors?.first)
            }
        }
    }
}

/// A shimmering line for what the turn is doing while it has nothing else to show.
struct ActivityLine: View {
    let text: String

    var body: some View {
        ActivityLabel(text: text, live: true)
            .fontWeight(.medium)
            .scaledFont(.callout)
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
    OlderHistoryTrigger(thread: .sampleIdleChat(), connection: nil, gaveUp: true)
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

extension EnvironmentValues {
    @Entry var turnHover: TurnHover? = nil
    @Entry var turnPlace: TurnPlace? = nil
}
