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
    /// The last line or two the end grew by, eased away: see `follow`.
    @State private var glide = Glide()
    @Environment(\.transcriptFind) private var find
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            TranscriptContent(thread: thread, connection: connection)
                .keyframeAnimator(initialValue: 0, trigger: glide.count) { content, y in
                    // Drawing only: an offset moves the content's geometry, and the lazy stack
                    // worked out again which rows it shows on every frame of the glide.
                    content.visualEffect { effect, _ in effect.offset(y: y) }
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(glide.distance)
                        CubicKeyframe(0, duration: 0.3)
                    }
                }
        }
        // Opens at the end and keeps it pinned through content and size changes. A transcript shorter
        // than the window sits at the top: aligned to the bottom, it was pushed down by a scroll offset
        // and the toolbar's edge effect followed its top edge down the window.
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
        // An older page goes in above the reader, who stays on the row they were reading: the scroll
        // view kept the same offset from the top, which showed the page's first rows and left the
        // spinner that asks for the next one on screen, so it never asked again.
        .onChange(of: thread.rows.first?.id) { old, new in
            guard let old, new != old else { return }
            // Once the page's rows exist, on the next turn of the run loop.
            Task { position.scrollTo(id: old, anchor: .top) }
        }
        // Find Next and Previous bring the match into view; the reader has left the end to read it.
        .onChange(of: find?.step) {
            guard let id = find?.current else { return }
            followsEnd = false
            withAnimation { position.scrollTo(id: id, anchor: .center) }
        }
        .onScrollGeometryChange(for: Extent.self, of: { Extent(content: $0.contentSize.height, container: $0.containerSize) }) {
            follow(from: $0, to: $1)
        }
        .onScrollPhaseChange { old, new, context in
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
                        followsEnd = true
                        withAnimation { position.scrollTo(edge: .bottom) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Scroll to the newest message")
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Scoped to the button so the transcript's own layout changes don't animate.
            .animation(.snappy, value: followsEnd)
        }
    }
}

extension TranscriptView {
    /// What following the end depends on: how tall the content is, and the size of the view.
    struct Extent: Equatable {
        let content: CGFloat
        let container: CGSize
    }

    /// A distance the content is drawn below where it is, easing back to nothing.
    struct Glide {
        var distance: CGFloat = 0
        var count = 0
    }

    /// Keeps the end in view while the reader is following it. The scroll view's anchor holds it
    /// there, which moves the transcript up a whole line at once when a streamed reply wraps; so
    /// the content is drawn that line lower and eased back up, and the new line glides into view.
    /// Drawing only, no layout. Not for a resize, whose rows all re-measure, or a jump bigger than
    /// a few lines, or with Reduce Motion.
    ///
    /// Switching the anchor off for this instead (and scrolling to the end by hand) made every frame
    /// of a resize slower, and switching it during layout made AppKit throw.
    private func follow(from old: Extent, to new: Extent) {
        guard followsEnd else { return }
        // The anchor doesn't survive a width change: every row re-measures at the new width.
        if old.container != new.container {
            position.scrollTo(edge: .bottom)
            return
        }
        let growth = new.content - old.content
        guard growth > 0, growth < 160, !reduceMotion else { return }
        glide = Glide(distance: growth, count: glide.count + 1)
    }
}

/// The rows. Only this view and the rows read `thread.rows`; everything that is not a row is its
/// own view, so a connection or turn change doesn't invalidate the whole list.
private struct TranscriptContent: View {
    let thread: ThreadModel
    let connection: HostConnection?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if !thread.historyLoaded {
                TranscriptUnavailable(thread: thread, connection: connection)
            }
            if thread.historyLoaded, thread.hasMoreHistory {
                OlderHistoryTrigger(thread: thread, connection: connection)
            }
            // One plain view per row, identified by the ForEach alone: a `switch` or `.id()` here
            // adds a node to every row, and the lazy stack walks every row on each layout pass.
            ForEach(thread.rows, id: \.id) { row in
                TranscriptRowView(row: row, thread: thread)
            }
            TranscriptTail(thread: thread)
        }
        // Rows are scroll targets by their ids, so an older page can keep the reader where they were.
        .scrollTargetLayout()
        // The size every row's text starts from; View ▸ Bigger and Smaller change it.
        .scaledFont(.body)
        .padding(.vertical, 16)
        .readingColumn()
    }
}

/// Asks for the previous page while the top of the transcript is on screen, one page at a time.
private struct OlderHistoryTrigger: View {
    let thread: ThreadModel
    let connection: HostConnection?
    @State private var visible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            // A page goes in above the reader and normally takes the spinner off screen, which ends
            // this. One short enough to leave it showing changes no visibility, so after a moment for
            // the scroll to settle the next page is asked for here.
            .task(id: visible) {
                while visible, thread.hasMoreHistory, !Task.isCancelled {
                    await connection?.loadOlderHistory(thread)
                    try? await Task.sleep(for: .milliseconds(300))
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

    nonisolated static func == (a: Self, b: Self) -> Bool {
        guard a.thread === b.thread else { return false }
        switch (a.row, b.row) {
        case (.item(let x), .item(let y)): return x.id == y.id
        case (.toolGroup(let x), .toolGroup(let y)): return x == y
        default: return false
        }
    }

    var body: some View {
        Group {
            switch row {
            case .item(let item):
                LiveItemView(box: thread.box(for: item), thread: thread)
                    .modifier(FadesIn(isNew: thread.justStarted(item.id)))
            case .toolGroup(let calls): ToolCallGroupView(calls: calls, thread: thread)
            }
        }
        .modifier(FindHighlight(id: row.id))
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

/// Stands in for the transcript before it arrives; a failure says so and offers a way out.
/// Its own view so `connection.state` and `thread.lastError` are not read in the transcript's body.
struct TranscriptUnavailable: View {
    let thread: ThreadModel
    var connection: HostConnection?

    var body: some View {
        if let error = thread.lastError {
            TranscriptPlaceholder("Couldn\u{2019}t Open This Chat", symbol: "exclamationmark.triangle", detail: error) {
                if let connection { Button("Try Again") { Task { await connection.open(thread) } } }
            }
        } else if case .failed(let message) = connection?.state {
            TranscriptPlaceholder("Not Connected", symbol: "bolt.horizontal.circle", detail: message) {
                if let connection { Button("Reconnect") { Task { await connection.reconnect() } } }
            }
        } else if case .disconnected = connection?.state {
            TranscriptPlaceholder("Not Connected", symbol: "bolt.horizontal.circle", detail: nil) {
                if let connection { Button("Connect") { Task { await connection.connect() } } }
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                if case .connecting(let message) = connection?.state {
                    Text(message).scaledFont(.callout).foregroundStyle(.secondary)
                }
            }
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
/// with thinking off or redacted.
struct ThinkingLine: View {
    var body: some View {
        Label("Thinking…", systemImage: "ellipsis")
            .symbolEffect(.variableColor.iterative, options: .repeating)
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
            .transition(.opacity)
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
                Label(error ?? "The turn failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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

/// What stands in for a transcript that hasn't arrived: the host is down, …
#Preview("TranscriptView (not connected)") {
    TranscriptView(thread: .sampleUnloaded(), connection: .sampleDisconnected())
        .frame(width: 900, height: 420)
}

/// … or the chat itself couldn't be opened.
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

#endif
