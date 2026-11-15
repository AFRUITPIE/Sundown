import SundownFixtures
import SwiftUI
import SundownKit
import TetherProtocol

/// The scrolling transcript: settled history, windowed (`TranscriptHistoryView`), then the live
/// turn (`TranscriptLiveView`), then the tail, in one scroll view, with what floats over it. Where
/// the reader is, and every row's height, is `TranscriptModel`'s.
struct TranscriptView: View {
    let thread: ThreadModel
    var connection: HostConnection?
    /// Room after the end for the controls floating over it (`ThreadView`'s bottom bar).
    var bottomRoom: CGFloat = 0
    @State private var model = TranscriptModel()
    @State private var turnHover = TurnHover()
    @Namespace private var rotor
    @Environment(\.transcriptFind) private var find
    @Environment(\.promptNavigator) private var promptNavigator
    @Environment(\.appearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.messageSendGeometry) private var sendGeometry
    /// Under Tasks or Diff: no Jump to Latest, and the geometry isn't the reader's.
    @Environment(\.transcriptHidden) private var hidden

    var body: some View {
        @Bindable var model = model
        ScrollView {
            TranscriptContent(model: model, thread: thread, connection: connection, bottomRoom: bottomRoom, rotor: rotor)
        }
        .scrollPosition($model.position)
        .defaultScrollAnchor(.bottom)
        // A short transcript sits at the top: bottom-aligned, it pushed the top edge effect down.
        .defaultScrollAnchor(.top, for: .alignment)
        .accessibilityLabel("Transcript")
        .onScrollGeometryChange(for: TranscriptModel.ViewGeometry.self) { g in
            TranscriptModel.ViewGeometry(offset: g.contentOffset.y, visibleTop: g.visibleRect.minY,
                                         visibleBottom: g.visibleRect.maxY, content: g.contentSize.height,
                                         container: g.containerSize, contentInsetTop: g.contentInsets.top)
        } action: { _, g in model.scrolled(g) }
        .environment(\.turnHover, turnHover)
        .environment(\.rowExpansion, model.expansion)
        .background { EnvironmentTap(model: model) }
        .onChange(of: thread.id, initial: true) { model.show(thread, connection: connection, folding: appearance.toolCalls.folding) }
        .onChange(of: appearance.toolCalls.folding) { model.show(thread, connection: connection, folding: appearance.toolCalls.folding) }
        .onChange(of: hidden, initial: true) { model.hidden = hidden }
        // Sending from this window goes back to the end, where the prompt is about to land.
        .onChange(of: sendGeometry?.sends) { model.goToEnd() }
        // Find Next and Previous bring the match into view.
        .onChange(of: find?.step) { if let id = find?.current { model.show(match: id) } }
        // Chat ▸ Previous and Next Prompt, from where the reader is.
        .onChange(of: promptNavigator?.step) { if let promptNavigator { model.goToPrompt(promptNavigator.direction) } }
        // Loading, in the middle of the page above the bottom bar rather than a row at the top.
        .overlay { TranscriptLoading(thread: thread, connection: connection, measuring: !model.ready).padding(.bottom, bottomRoom) }
        .overlay(alignment: .bottom) { jumpToLatest }
    }

    /// Jump to Latest, while the reader is more than a screen from the end.
    private var jumpToLatest: some View {
        let far = model.farFromEnd && !hidden
        return ZStack {
            if far {
                Button("Jump to Latest", systemImage: "arrow.down") { model.goToEnd() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Jump to Latest")
                    // Never the key view: with keyboard navigation on, a click focused it, and as it
                    // went AppKit handed focus to the transcript's first row (CI, 2026-10-17).
                    // VoiceOver still presses it.
                    .focusable(false)
                    .padding(.bottom, 8)
                    .transition(.moving(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
            }
        }
        // Scoped to the button so the transcript's own layout changes don't animate.
        .animation(.snappy, value: far)
        // Above the bottom bar, outside the button's transition: inside it, the button slid in
        // from the bar's height below and was still on its way when clicked.
        .padding(.bottom, bottomRoom)
    }
}

/// Hands the transcript's environment to its model, for rows it measures before they're built.
/// Its own view, so reading the whole environment redraws nothing else.
private struct EnvironmentTap: View {
    let model: TranscriptModel
    @Environment(\.self) private var values

    var body: some View {
        Color.clear
            .onChange(of: RowMetrics(values), initial: true) { model.environment(values) }
    }
}

/// What the scroll view holds: the older-history row, the settled rows, the live turn and the tail.
private struct TranscriptContent: View {
    let model: TranscriptModel
    let thread: ThreadModel
    let connection: HostConnection?
    let bottomRoom: CGFloat
    let rotor: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !thread.historyLoaded {
                TranscriptUnavailable(thread: thread, connection: connection)
                    .frame(maxWidth: .infinity)
            }
            if model.ready {
                if model.showsOlder {
                    OlderHistoryRow(failed: model.olderFailed) { model.retryOlder() }
                        .frame(height: TranscriptModel.olderRowHeight)
                        .padding(.bottom, TranscriptModel.spacing)
                }
                TranscriptHistoryView(model: model, thread: thread, rotor: rotor)
                TranscriptLiveView(model: model, thread: thread, rotor: rotor)
            }
            // The end: what's happening now, and room under the controls floating over it.
            VStack(alignment: .leading, spacing: 0) { TranscriptTail(thread: thread) }
                .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
                .scaledFont(.body)
                .readingColumn()
                .padding(.bottom, bottomRoom + 2)
        }
        .padding(.top, TranscriptModel.topPadding)
        .background { ScrollKeeper(model: model) }
        // The width rows are laid out at, which their heights are for.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.widthChanged($0) }
        // VoiceOver's way from prompt to prompt, which reaches rows not built: each entry brings its
        // row into view first.
        .accessibilityElement(children: .contain)
        .accessibilityRotor("Prompts") {
            ForEach(thread.prompts(model.folding)) { prompt in
                AccessibilityRotorEntry(Text(prompt.label), id: prompt.id, in: rotor) { model.reveal(prompt.id) }
            }
        }
    }
}

/// The settled rows: those near the view built, the rest as the room they take, known exactly
/// (`HeightIndex`). Redrawn only when the settled rows, their heights or the rows built change:
/// never for a streamed delta.
struct TranscriptHistoryView: View {
    let model: TranscriptModel
    let thread: ThreadModel
    let rotor: Namespace.ID

    var body: some View {
        let index = model.index
        let window = model.window.clamped(to: 0..<model.settled.count)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: index.top(window.lowerBound))
            ForEach(model.settled[window]) { entry in
                TranscriptRowCell(entry: entry, thread: thread, model: model, live: false, rotor: rotor)
            }
            Color.clear.frame(height: index.total - index.top(window.upperBound))
        }
        .readingColumn()
    }
}

/// The running turn's rows, under the history: its rows grow and change here without the history
/// knowing. All built, in a plain stack, so the content's height is its rows' and never an
/// estimate: a lazy stack here guessed the height of rows it hadn't built, and once a long reply
/// finished the end the reader followed was past the last row, a blank transcript (2026-11).
struct TranscriptLiveView: View {
    let model: TranscriptModel
    let thread: ThreadModel
    let rotor: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.live) { entry in
                TranscriptRowCell(entry: entry, thread: thread, model: model, live: true, rotor: rotor)
            }
        }
        .readingColumn()
    }
}

/// One built row, saying its height as it lays out, and the spacing after it.
struct TranscriptRowCell: View, Equatable {
    let entry: TranscriptEntry
    let thread: ThreadModel
    let model: TranscriptModel
    let live: Bool
    let rotor: Namespace.ID

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.live == b.live && a.model === b.model && a.rotor == b.rotor
            && TranscriptRowView(row: a.entry.row, thread: a.thread, place: a.entry.place)
                == TranscriptRowView(row: b.entry.row, thread: b.thread, place: b.entry.place)
    }

    var body: some View {
        let id = entry.id, live = live
        TranscriptRowContent(entry: entry, thread: thread)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [model] in
                model.reported($0, for: id, live: live)
            }
            .accessibilityRotorEntry(id: id, in: rotor)
            .padding(.bottom, TranscriptModel.spacing)
    }
}

/// The row above the rows while older history is there: a spinner while the transcript asks for
/// the next page as the reader nears the top (`TranscriptModel`), and, once a page has failed a few
/// times, why, with Try Again.
struct OlderHistoryRow: View {
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        VStack {
            if failed {
                HStack {
                    Label("Couldn’t Load Earlier Messages", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: retry)
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
    }
}

/// One transcript row: an item, read live from its box, or a group of finished tool calls.
/// Equatable, so a row is drawn again only when it draws differently: an item's row is the same row
/// as long as it is the same item, since it reads the item's current state from its box.
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
        .transformEnvironment(\.turnPlace) { if let place { $0 = place } }
        // Anywhere in a turn shows its actions, after its last reply.
        .onHover { inside in if let place { turnHover?.pointer(inside, turn: place.turn) } }
    }
}

/// A row for an item that just started fades in rather than popping in. Opacity only, so it suits
/// Reduce Motion as it is.
/// The person's own just-sent prompt pushes in from below instead, on a spring, driven from
/// `onAppear` like the fade: the row's hosting view is made as it appears, so an insertion
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
    /// Loaded, while the rows are measured before they're shown.
    var measuring = false

    var body: some View {
        if !thread.historyLoaded || measuring, TranscriptUnavailable.failure(thread, connection) == nil {
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
        // A turn that finished normally says nothing.
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
    @Environment(\.windowRef) private var windowRef

    var body: some View {
        Button { windowRef.window?.tab = .tasks } label: {
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
    var items: [Item] = [.userMessage(.sample("Check each part of the renderer.", secondsAgo: 100))]
    for index in 0..<40 {
        let ago = Double(90 - index * 2)
        items.append(.toolCall(.sample(name: "Read", kind: .fileRead,
                                    input: ["file_path": .string("/tmp/Renderer\(index).swift")],
                                    status: .completed, secondsAgo: ago)))
        items.append(.agentMessage(.sample("Checked renderer \(index). Continuing with the next part.", secondsAgo: ago - 1)))
    }
    items.append(.agentMessage(.sample("## Finished\n\nThe renderer's checks are complete.", secondsAgo: 4)))
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
    OlderHistoryRow(failed: true) {}
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

extension EnvironmentValues {
    @Entry var transcriptHidden = false
    @Entry var turnHover: TurnHover? = nil
    @Entry var turnPlace: TurnPlace? = nil
}

/// The spring a sent prompt pushes in with.
private enum TranscriptMotion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.8)
}
