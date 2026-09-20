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
            // Same treatment at the top, so the transcript fades under the controls the way it
            // fades under the composer instead of meeting them at a hard rule.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(thread.title)
            .navigationSubtitle(thread.cwd?.abbreviatingHome ?? "")
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
    /// Paging older history only starts once the transcript has settled at its end. Before that
    /// the top of a short page is on screen, and asking for older items there would walk the
    /// whole session backwards without anyone having scrolled.
    @State private var readyForPaging = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !thread.historyLoaded { unloadedState }
                if thread.historyLoaded, thread.hasMoreHistory {
                    // Asking for the previous page when the top of this one comes into view, the
                    // mirror of the anchor at the end. `loadOlderHistory` takes one page at a
                    // time, so repeated calls while a page is in flight are harmless.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            guard visible, readyForPaging else { return }
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
                // Whether the end of the transcript is on screen, asked rather than calculated.
                // The arithmetic this replaces added the top inset to the maximum offset,
                // inflating it by about the height of the toolbar, so with a 40pt tolerance the
                // test could never come true and the button never went away.
                //
                // The last child rather than an overlay on the stack: an overlay has to be sized
                // against the stack, which asks a LazyVStack for a height it can only give by
                // measuring every row — and re-measuring all of them on each frame of a column
                // resize is the one thing worth avoiding here.
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
        // Start at the bottom, and follow new output only while the reader is already there —
        // scrolling up to read something stays put, with a way back to the live end.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($position)
        // Rows in a LazyVStack are measured as they come into range, so the content keeps growing
        // for a while after history arrives — following the content size covers both that and
        // streamed output, where watching the items alone would stop short of the end.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            guard atBottom else { return }
            position.scrollTo(edge: .bottom)
        }
        // A newly opened chat starts at its latest message, wherever the reader left the last one.
        .onChange(of: thread.historyLoaded) {
            guard thread.historyLoaded else { return }
            atBottom = true
            readyForPaging = false
            position.scrollTo(edge: .bottom)
        }
        // The first content-size change after loading is the transcript settling at its end;
        // paging older history is only sensible after that.
        .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > 0 } action: { _, hasContent in
            if hasContent, thread.historyLoaded { readyForPaging = true }
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
            }
        }
        .animation(.snappy, value: atBottom)
    }

    /// What stands in for the transcript before it arrives. A bare spinner is only right while
    /// something is actually in flight — if the load failed, or the host isn't reachable, that
    /// says so and offers the way out, rather than turning forever.
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

/// Marks the wait before a turn has anything to show. Reasoning itself isn't rendered, so this
/// is all there is between sending and the first words of the reply — it comes from the thread's
/// status rather than reasoning items, so it works with thinking off or redacted too.
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

/// Model, effort, fast mode and permission menus for a live chat (shown in the window toolbar).
struct ThreadControls: View {
    let thread: ThreadModel
    let connection: HostConnection

    private var currentModelInfo: ModelInfo? {
        let m = connection.models.concreteValue(for: thread.info?.model)
        return connection.models.concrete.first { $0.value == m } ?? connection.models.concrete.first
    }

    var body: some View {
        // Falls back to the catalog's first entry only until the server reports the thread's real
        // model — with no Default row, an unmatched selection would draw as a blank button.
        ModelPicker(selection: Binding(get: { connection.models.concreteValue(for: thread.info?.model) },
                                       set: { m in Task { await connection.setModel(thread, m) } }),
                    models: connection.models)
        EffortPicker(selection: Binding(get: { thread.info?.effort ?? nil }, set: { e in Task { await connection.setEffort(thread, e) } }),
                     levels: currentModelInfo?.supportedEffortLevels ?? EffortLevel.allCases)
        PermissionModePicker(selection: Binding(
            get: { thread.info?.permissionMode ?? .default },
            set: { m in Task { await connection.setPermissionMode(thread, m) } }))
        if currentModelInfo?.supportsFastMode == true {
            Toggle("Fast", systemImage: "hare", isOn: Binding(
                get: { thread.info?.fastModeState == "on" },
                set: { on in Task { await connection.setFastMode(thread, on) } }))
                .toggleStyle(.button)
                .disabled(thread.info?.fastModeDisabledReason != nil)
                .help(thread.info?.fastModeDisabledReason.map { "Fast mode unavailable: \($0)" } ?? "Fast mode")
        }
    }
}

// These three choose one value from a flat set of mutually exclusive options and show the current
// one on the button, which is a pop-up button — not the pull-down button a bare `Menu` produces.
// (HIG, Pop-up buttons: "Use a pop-up button to present a flat list of mutually exclusive options
// or states"; use a pull-down button instead to "offer a list of actions".) `.menu` is the picker
// style that renders as one. The help text is the introductory label HIG asks for, so the options
// are predictable without opening the menu.
//
// All three are text-only, matching the family and weight pop-ups in the SF Symbols app — which
// stay text-only even for weight, an ordinal value a gauge could have described.
struct ModelPicker: View {
    @Binding var selection: String?
    let models: [ModelInfo]

    var body: some View {
        // No "Default (recommended)" row: the CLI lists it as a pseudo-model, but its
        // `resolvedModel` says which real model it stands for, so the picker shows that one
        // selected instead of a word that names nothing.
        Picker("Model", selection: $selection) {
            ForEach(models.concrete, id: \.value) { m in
                Text(m.shortName).tag(Optional(m.value))
            }
            // Keep a custom or Bedrock model ID selectable even if the CLI does not list it.
            if let s = selection, !models.contains(where: { $0.value == s || $0.resolvedModel == s }) {
                Text(s).tag(Optional(s))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help("Model")
    }
}

struct EffortPicker: View {
    @Binding var selection: EffortLevel?
    let levels: [EffortLevel]

    var body: some View {
        Picker("Effort", selection: $selection) {
            // Unlike the model, this one is a real choice and not a stand-in for an unknown:
            // sending no effort is what lets a model that supports it decide per turn.
            Text("Automatic").tag(EffortLevel?.none)
            ForEach(levels, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help("Reasoning effort")
    }
}

struct PermissionModePicker: View {
    @Binding var selection: PermissionMode

    var body: some View {
        Picker("Permissions", selection: $selection) {
            ForEach([PermissionMode.default, .acceptEdits, .plan, .auto, .dontAsk, .bypassPermissions], id: \.self) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help("Permission mode")
    }
}

/// Trailing inspector, split into three panes. A segmented control switches them: it's one click
/// per pane and shows every choice at once, which HIG prefers over a pop-up button for switching
/// panes, and a tab view's enclosure would be redundant inside a column that is already enclosed.
/// Three segments, equal width, text only — no mixing text and icons in one control.
struct ThreadInspector: View {
    let thread: ThreadModel
    let connection: HostConnection
    @State private var pane: Pane
    @State private var usage: Loaded<JSONValue?> = .loading

    init(thread: ThreadModel, connection: HostConnection, pane: Pane = .tasks) {
        self.thread = thread
        self.connection = connection
        self._pane = State(initialValue: pane)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case tasks = "Tasks"
        case session = "Session"
        case mcp = "MCP"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector pane", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch pane {
                case .tasks: tasksPane
                case .session: sessionPane
                case .mcp: mcpPane
                }
            }
            .formStyle(.grouped)
            // Let the inspector's own material show through: a grouped Form paints its background
            // below the titlebar area, which reads as a header strip sitting on top of the column.
            .scrollContentBackground(.hidden)
            // Values truncate instead of widening the column (a min width > max width loops the split view).
            .lineLimit(1)
        }
        // Keyed on the thread too: two chats with the same turn count would otherwise leave the
        // task un-rerun, and the inspector would keep showing the previous chat's context.
        .task(id: Key(threadId: thread.id, turns: thread.turns.count)) { await refresh() }
    }

    private struct Key: Equatable { let threadId: String; let turns: Int }

    // MARK: panes

    private var tasks: [TaskEventNotification] { thread.tasks.values.sorted { $0.seq < $1.seq } }

    @ViewBuilder private var tasksPane: some View {
        if tasks.isEmpty {
            InspectorEmptyState("No Tasks", symbol: "person.2",
                                detail: "Subagents and workflows this chat starts show up here while they run.")
        } else {
            Form {
                Section {
                    ForEach(tasks, id: \.taskId) { t in
                        TaskRow(task: t)
                    }
                }
            }
        }
    }

    @ViewBuilder private var sessionPane: some View {
        Form {
            Section("Context") {
                switch usage {
                case .loading:
                    // Transient by contract: every other branch below replaces it with something
                    // readable, so this can't be left spinning at a dead end.
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                case .ready(let u):
                    contextBody(u)
                }
                Button("Refresh") { Task { await refresh() } }
                    .disabled(usage.isLoading)
            }
            Section("Cost") {
                LabeledContent("This thread", value: Format.cost(thread.totalCostUsd))
                if let last = thread.turns.last?.result {
                    LabeledContent("Last turn", value: Format.cost(last.totalCostUsd))
                    LabeledContent("Duration", value: Format.duration(last.durationMs / 1000))
                }
            }
            if let info = thread.info {
                Section("Session") {
                    LabeledContent("Status", value: info.status.rawValue)
                    LabeledContent("Directory") { Text(info.cwd.abbreviatingHome).truncationMode(.middle) }
                    if let v = info.claudeCodeVersion { LabeledContent("Claude Code", value: v) }
                    if let o = info.outputStyle { LabeledContent("Output style", value: o) }
                    LabeledContent("Thread ID") { Text(info.threadId).textSelection(.enabled).font(.caption.monospaced()).truncationMode(.middle) }
                }
            }
        }
    }

    @ViewBuilder private var mcpPane: some View {
        let servers = thread.info?.mcpServers ?? []
        if servers.isEmpty {
            InspectorEmptyState("No MCP Servers", symbol: "puzzlepiece.extension",
                                detail: thread.info == nil
                                    ? "Server status arrives once this chat is running."
                                    : "This chat's Claude Code configuration has no MCP servers.")
        } else {
            Form {
                Section {
                    ForEach(servers, id: \.name) { s in
                        LabeledContent(s.name) {
                            Label(s.status, systemImage: symbol(for: s.status))
                                .foregroundStyle(tint(for: s.status))
                        }
                    }
                }
            }
        }
    }

    /// Status carries a symbol as well as a color, so it doesn't rely on color alone.
    private func symbol(for status: String) -> String {
        switch status {
        case "connected", "ready": return "checkmark.circle.fill"
        case "connecting", "pending": return "clock"
        case "failed", "error": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private func tint(for status: String) -> Color {
        switch status {
        case "connected", "ready": return .green
        case "failed", "error": return .red
        default: return .secondary
        }
    }

    @ViewBuilder private func contextBody(_ u: JSONValue?) -> some View {
        if let u {
            let total = u["totalTokens"]?.doubleValue ?? 0
            let limit = u["maxTokens"]?.doubleValue ?? u["rawMaxTokens"]?.doubleValue ?? 0
            if limit > 0 {
                Gauge(value: min(total / limit, 1)) {
                    Text("Context window")
                } currentValueLabel: {
                    Text("\(Format.tokens(total)) of \(Format.tokens(limit))")
                }
            }
            ForEach(u["categories"]?.arrayValue ?? [], id: \.self) { c in
                LabeledContent(c.string("name") ?? "", value: Format.tokens(c["tokens"]?.doubleValue ?? 0))
            }
        } else {
            Text("No context reported yet.").foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        // The daemon only answers for a thread it has loaded, so say so rather than spinning:
        // sending a message resumes the thread and the next refresh succeeds.
        guard connection.isLoaded(thread) else {
            usage = .failed("Available once this chat is running — send a message to resume it.")
            return
        }
        usage = .loading
        do {
            usage = .ready(try await connection.contextUsage(thread))
        } catch is CancellationError {
            // Superseded by a newer refresh; that one owns the state from here.
        } catch {
            usage = .failed(error.localizedDescription)
        }
    }
}

/// One subagent or workflow run: what it is, and whether it's still going.
struct TaskRow: View {
    let task: TaskEventNotification

    private var isRunning: Bool {
        let state = task.status ?? task.event
        return !["completed", "failed", "stopped", "task_completed", "task_failed"].contains(state)
    }

    var body: some View {
        LabeledContent {
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Text(task.status ?? task.event).foregroundStyle(.secondary)
            }
        } label: {
            Text(task.description ?? task.taskId).lineLimit(2)
        }
    }
}

/// An inspector pane with nothing in it yet — says which, rather than showing a blank column.
struct InspectorEmptyState: View {
    let title: String
    let symbol: String
    let detail: String

    init(_ title: String, symbol: String, detail: String) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail).lineLimit(nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A value that has to be fetched: every case renders as something, so a view can never be left
/// showing a spinner that has nothing behind it.
enum Loaded<Value> {
    case loading
    case ready(Value)
    case failed(String)

    var isLoading: Bool { if case .loading = self { return true }; return false }
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

// Inspector visibility now lives on AppModel (hoisted so `.inspector` can span the whole window),
// so a bare ThreadView never shows one — see "Tool call gallery (inspector open)" below, which
// wraps this same thread in a NavigationSplitView with the inspector forced open explicitly.
// This preview shows the transcript alone: a thread with a rich variety of tool calls.
#Preview("Tool call gallery") {
    NavigationStack {
        ThreadView(thread: .sampleToolCalls(), connection: .sample())
    }
    .frame(width: 1100, height: 760)
}

#Preview("Tool call gallery (inspector open)") {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        ThreadView(thread: .sampleToolCalls(), connection: .sample())
    }
    .inspector(isPresented: .constant(true)) {
        ThreadInspector(thread: .sampleToolCalls(), connection: .sample())
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
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

#Preview("ThreadControls") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleIdleChat()
    HStack(spacing: 4) { ThreadControls(thread: thread, connection: connection) }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(20)
        .frame(width: 560)
}

#Preview("ModelPicker") {
    ModelPicker(selection: .constant("sonnet"), models: ModelInfo.sampleCatalog)
        .padding(20)
        .frame(width: 260)
}

#Preview("EffortPicker") {
    EffortPicker(selection: .constant(.high), levels: [.low, .medium, .high, .max])
        .padding(20)
        .frame(width: 260)
}

#Preview("PermissionModePicker") {
    PermissionModePicker(selection: .constant(.acceptEdits))
        .padding(20)
        .frame(width: 260)
}

#Preview("Inspector — Tasks") {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        Text("Detail")
            .inspector(isPresented: .constant(true)) {
                ThreadInspector(thread: .sampleWithTasks(), connection: .sample())
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
    .frame(width: 900, height: 560)
}

#Preview("Inspector — Tasks (empty)") {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        Text("Detail")
            .inspector(isPresented: .constant(true)) {
                ThreadInspector(thread: .sampleIdleChat(), connection: .sample())
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
    .frame(width: 900, height: 560)
}

#Preview("Inspector — Session") {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        Text("Detail")
            .inspector(isPresented: .constant(true)) {
                ThreadInspector(thread: .sampleWithTasks(), connection: .sample(), pane: .session)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
    .frame(width: 900, height: 700)
}

#Preview("Inspector — MCP") {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        Text("Detail")
            .inspector(isPresented: .constant(true)) {
                ThreadInspector(thread: .sampleWithTasks(), connection: .sample(), pane: .mcp)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
    .frame(width: 900, height: 480)
}

#Preview("ThreadInspector") {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        Text("Detail")
            .inspector(isPresented: .constant(true)) {
                ThreadInspector(thread: .sampleToolCalls(), connection: .sample())
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
    .frame(width: 900, height: 700)
}

#endif
