import SwiftUI
import TetherKit
import TetherProtocol

struct ThreadView: View {
    let thread: ThreadModel
    let connection: HostConnection

    var body: some View {
        TranscriptView(thread: thread, connection: connection)
            // Controls float over the transcript on glass; content scrolls underneath with a soft edge.
            .safeAreaBar(edge: .bottom) {
                BottomBar(thread: thread, connection: connection)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // The same soft edge under the toolbar.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Title and subtitle belong to the shell's detail container, not to this view.
            .task(id: thread.id) { await connection.open(thread) }
    }
}

/// Pending prompts, status and the composer, grouped so their glass shapes blend.
struct BottomBar: View {
    let thread: ThreadModel
    let connection: HostConnection
    @Environment(\.readingWidth) private var readingWidth

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                StatusStrip(thread: thread)
                if let p = thread.pending.first {
                    PendingRequestView(pending: p, thread: thread)
                        .id(p.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Composer(connection: connection, cwd: thread.cwd, thread: thread, onStop: {
                        Task { await connection.interrupt(thread) }
                    }, submit: { input in
                        await connection.send(thread, input: input)
                    })
                }
            }
            .animation(.snappy, value: thread.pending.first?.id)
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.bottom, 14)
        .frame(maxWidth: readingWidth)
        .frame(maxWidth: .infinity)
    }
}

struct TranscriptView: View {
    let thread: ThreadModel
    var connection: HostConnection?
    @Environment(\.readingWidth) private var readingWidth
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !thread.historyLoaded { unloadedState }
                if thread.historyLoaded, thread.hasMoreHistory {
                    // Ask for the previous page when the top comes into view; one page is fetched at a time.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            guard visible else { return }
                            Task { await connection?.loadOlderHistory(thread) }
                        }
                }
                ForEach(thread.rows, id: \.id) { row in
                    switch row {
                    case .item(let item): ItemView(item: item, thread: thread).id(item.id)
                    case .toolGroup(let calls): ToolCallGroupView(calls: calls, thread: thread).id(row.id)
                    }
                }
                if thread.isThinking { ThinkingLine() }
                if let turn = thread.turns.last, turn.status != .inProgress, let r = turn.result {
                    TurnFooter(result: r, status: turn.status)
                }
                // Whether the end is on screen. The last child rather than an overlay, which would make
                // the LazyVStack measure every row.
                Color.clear
                    .frame(height: 1)
                    .allowsHitTesting(false)
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        atBottom = visible
                    }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: readingWidth)
            .frame(maxWidth: .infinity)
        }
        // Every role, so the framework also keeps the bottom pinned through content and size changes.
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        // A newly opened chat starts at its latest message.
        .onChange(of: thread.historyLoaded) {
            guard thread.historyLoaded else { return }
            atBottom = true
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

    /// Stands in for the transcript before it arrives; a failure says so and offers a way out.
    @ViewBuilder private var unloadedState: some View {
        Group {
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

struct StatusStrip: View {
    let thread: ThreadModel

    var body: some View {
        let parts = messages
        let auth = thread.authStatus.flatMap { $0.isAuthenticating || $0.error != nil ? $0 : nil }
        if !parts.isEmpty || auth != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(parts, id: \.self) { m in
                    Text(m).font(.callout).lineLimit(3)
                }
                if let auth { AuthStatusView(status: auth) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(thread.lastError != nil ? .red.opacity(0.25) : nil), in: .rect(cornerRadius: 18))
        }
    }

    private var messages: [String] {
        var out: [String] = []
        if let e = thread.lastError { out.append(e) }
        if let r = thread.apiRetry { out.append("Retrying API request (attempt \(r.attempt)/\(r.maxRetries))\(r.error.map { ": \($0)" } ?? "")") }
        if thread.activity == "compacting" { out.append("Compacting conversation…") }
        return out
    }
}

/// Shows `awsAuthRefresh` / login helper output (e.g. AWS SSO device-code URLs) with clickable links.
struct AuthStatusView: View {
    let status: ThreadAuthStatusNotification
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(status.isAuthenticating ? "Refreshing credentials…" : "Authentication problem", systemImage: "key")
                .font(.caption.bold())
            ForEach(Array(status.output.suffix(8).enumerated()), id: \.offset) { _, line in
                if let url = line.firstMatch(of: /https?:\/\/\S+/).flatMap({ URL(string: String($0.output)) }) {
                    Link(line, destination: url).font(.caption.monospaced())
                } else {
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let e = status.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }
}

#if DEBUG
#Preview("Idle chat") {
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .sampleIdleChat(), connection: connection)
    }
    .frame(width: 900, height: 700)
}

#Preview("Running turn") {
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .sampleRunningTurn(), connection: connection)
    }
    .frame(width: 900, height: 700)
}

#Preview("Thinking (nothing to show yet)") {
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .sample(status: .running, items: [
            .sampleUserMessage("Why does opening a chat with the inspector open throw a constraints exception?", secondsAgo: 3),
        ]), connection: connection)
    }
    .frame(width: 900, height: 400)
}

#Preview("Pending permission") {
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .samplePendingPermission(), connection: connection)
    }
    .frame(width: 900, height: 700)
}

// The transcript alone; the inspector has its own previews in `Inspector/`.
#Preview("Tool call gallery") {
    NavigationStack {
        ThreadView(thread: .sampleToolCalls(), connection: .sample())
    }
    .frame(width: 1100, height: 760)
}

#Preview("BottomBar (composer)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleIdleChat()
    VStack {
        Spacer()
        BottomBar(thread: thread, connection: connection)
    }
    .frame(width: 900, height: 220)
}

#Preview("BottomBar (pending request)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.samplePendingPermission()
    VStack {
        Spacer()
        BottomBar(thread: thread, connection: connection)
    }
    .frame(width: 900, height: 320)
}

#Preview("TranscriptView") {
    TranscriptView(thread: .sampleToolCalls())
        .frame(width: 900, height: 760)
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

#Preview("StatusStrip") {
    VStack(alignment: .leading, spacing: 16) {
        StatusStrip(thread: .sampleErrorTurn())
        StatusStrip(thread: .sampleApiRetry())
    }
    .padding(20)
    .frame(width: 560)
}

#Preview("AuthStatusView") {
    AuthStatusView(status: .init(threadId: "preview-thread", seq: 1, isAuthenticating: true,
                                  output: ["Visit https://device.sso.us-west-2.amazonaws.com/", "Enter code: ABCD-EFGH"], error: nil))
        .padding(20)
        .frame(width: 480)
}

#endif
