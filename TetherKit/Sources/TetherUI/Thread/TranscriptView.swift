import SwiftUI
import TetherKit
import TetherProtocol

/// The scrolling transcript. Only this view and its rows read `thread.rows`; everything that is not
/// a row is its own view, so a connection or turn change doesn't invalidate the whole list.
struct TranscriptView: View {
    let thread: ThreadModel
    var connection: HostConnection?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !thread.historyLoaded {
                    TranscriptUnavailable(thread: thread, connection: connection)
                }
                if thread.historyLoaded, thread.hasMoreHistory {
                    olderHistoryTrigger
                }
                ForEach(thread.rows, id: \.id) { row in
                    switch row {
                    case .item(let item): ItemView(item: item, thread: thread).id(item.id)
                    case .toolGroup(let calls): ToolCallGroupView(calls: calls, thread: thread).id(row.id)
                    }
                }
                TranscriptTail(thread: thread)
                bottomSentinel
            }
            .padding(.vertical, 16)
            .readingColumn()
        }
        // Every role, so the framework also keeps the bottom pinned through content and size changes.
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        // A newly opened chat starts at its latest message.
        .onChange(of: thread.historyLoaded) {
            guard thread.historyLoaded else { return }
            if !atBottom { atBottom = true }
            position.scrollTo(edge: .bottom)
        }
        .overlay(alignment: .bottom) {
            if !atBottom {
                Button("Jump to Latest", systemImage: "arrow.down") {
                    withAnimation { position.scrollTo(edge: .bottom) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Jump to Latest")
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Scoped to the button so the transcript's own layout changes don't animate.
                .animation(.snappy, value: atBottom)
            }
        }
    }

    /// Asks for the previous page when the top comes into view; one page is fetched at a time.
    private var olderHistoryTrigger: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                // `loadingOlder` is checked here as well as inside the call: the spinner stays on
                // screen while its page loads, and every visibility report would queue another task.
                guard visible, !thread.loadingOlder else { return }
                Task { await connection?.loadOlderHistory(thread) }
            }
    }

    /// Whether the end is on screen. The last child rather than an overlay, which would make
    /// the LazyVStack measure every row.
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .allowsHitTesting(false)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                // Only on a real change. Visibility is reported again after the jump button appears
                // and after a chat swap re-anchors the scroll, and writing the value back unchanged
                // is the "tried to update multiple times per frame" complaint.
                guard atBottom != visible else { return }
                atBottom = visible
            }
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
                    Text(message).font(.callout).foregroundStyle(.secondary)
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
            if let detail { Text(detail) }
        } actions: {
            actions
        }
        .padding(.vertical, 40)
    }
}

/// The end of the transcript: the wait before a turn has anything to show, and the finished turn's
/// summary. Its own view so `isThinking` and `turns` are read here rather than beside the rows. A
/// `Group` rather than a stack, so that with neither of them the enclosing spacing collapses too.
struct TranscriptTail: View {
    let thread: ThreadModel

    var body: some View {
        Group {
            if thread.isThinking { ThinkingLine() }
            if let turn = thread.turns.last, turn.status != .inProgress, let result = turn.result {
                TurnFooter(result: result, status: turn.status)
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
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.opacity)
    }
}

struct TurnFooter: View {
    let result: TurnResult
    let status: TurnStatus

    var body: some View {
        HStack(spacing: 10) {
            if status == .interrupted { Label("Interrupted", systemImage: "stop.circle") }
            else if status == .failed { Label(result.errors?.first ?? result.subtype, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            Text(Format.duration(result.durationMs / 1000))
            Text(Format.cost(result.totalCostUsd))
            Text("\(Format.tokens(result.usage.inputTokens + result.usage.cacheReadInputTokens + result.usage.cacheCreationInputTokens)) in · \(Format.tokens(result.usage.outputTokens)) out")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
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

#Preview("TurnFooter") {
    VStack(alignment: .trailing, spacing: 12) {
        TurnFooter(result: .sample(), status: .completed)
        TurnFooter(result: .sample(subtype: "error_during_execution", isError: true, errors: ["SSH connection to deploy-01 timed out"]), status: .failed)
        TurnFooter(result: .sample(), status: .interrupted)
    }
    .padding(20)
    .frame(width: 500)
}

#endif
