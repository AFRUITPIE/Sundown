import SwiftUI
import TetherKit
import TetherProtocol

struct ThreadView: View {
    let thread: ThreadModel
    let connection: HostConnection
    @AppStorage("tether.inspector") private var showInspector = false

    var body: some View {
        TranscriptView(thread: thread)
            // Controls float over the transcript on glass; content scrolls underneath with a soft edge.
            .safeAreaBar(edge: .bottom) {
                BottomBar(thread: thread, connection: connection)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle(thread.title)
            .navigationSubtitle(thread.cwd?.abbreviatingHome ?? "")
            .toolbar { ThreadToolbar(thread: thread, connection: connection, showInspector: $showInspector) }
            .inspector(isPresented: $showInspector) {
                ThreadInspector(thread: thread, connection: connection)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .task(id: thread.id) { await connection.open(thread) }
    }
}

/// Pending prompts, status and the composer, grouped so their glass shapes blend.
struct BottomBar: View {
    let thread: ThreadModel
    let connection: HostConnection

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                StatusStrip(thread: thread)
                if let p = thread.pending.first {
                    PendingRequestView(pending: p, thread: thread)
                        .id(p.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Composer(connection: connection, cwd: thread.cwd, thread: thread) { input in
                        await connection.send(thread, input: input)
                    }
                }
            }
            .animation(.snappy, value: thread.pending.first?.id)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity)
    }
}

struct TranscriptView: View {
    let thread: ThreadModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !thread.historyLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                ForEach(thread.topLevelItems, id: \.id) { item in
                    ItemView(item: item, thread: thread).id(item.id)
                }
                if let turn = thread.turns.last, turn.status != .inProgress, let r = turn.result {
                    TurnFooter(result: r, status: turn.status)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        // Start at the bottom and stay pinned there as streamed content grows.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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

struct ThreadToolbar: ToolbarContent {
    let thread: ThreadModel
    let connection: HostConnection
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ModelPicker(selection: Binding(get: { thread.info?.model }, set: { m in Task { await connection.setModel(thread, m) } }),
                        models: connection.models)
            EffortPicker(selection: Binding(get: { thread.info?.effort ?? nil }, set: { e in Task { await connection.setEffort(thread, e) } }),
                         levels: currentModelInfo?.supportedEffortLevels ?? EffortLevel.allCases)
            if currentModelInfo?.supportsFastMode == true {
                Toggle("Fast mode", systemImage: "hare", isOn: Binding(
                    get: { thread.info?.fastModeState == "on" },
                    set: { on in Task { await connection.setFastMode(thread, on) } }))
                    .disabled(thread.info?.fastModeDisabledReason != nil)
                    .help(thread.info?.fastModeDisabledReason.map { "Fast mode unavailable: \($0)" } ?? "Fast mode")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            PermissionModePicker(selection: Binding(
                get: { thread.info?.permissionMode ?? .default },
                set: { m in Task { await connection.setPermissionMode(thread, m) } }))
        }
        if thread.isRunning {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Stop", systemImage: "stop.fill") { Task { await connection.interrupt(thread) } }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Toggle("Inspector", systemImage: "sidebar.trailing", isOn: $showInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private var currentModelInfo: ModelInfo? {
        let m = thread.info?.model
        return connection.models.first { $0.value == m || $0.resolvedModel == m } ?? connection.models.first
    }
}

/// Toolbar menus: a Menu whose content is an inline Picker gives native checkmarks and a clear label.
struct ModelPicker: View {
    @Binding var selection: String?
    let models: [ModelInfo]

    private var title: String {
        guard let s = selection else { return "Default" }
        return models.first { $0.value == s || $0.resolvedModel == s }?.displayName ?? s
    }

    var body: some View {
        Menu {
            Picker("Model", selection: $selection) {
                Text("Default").tag(String?.none)
                ForEach(models, id: \.value) { m in
                    Text(m.displayName).tag(Optional(m.value))
                }
                // Keep a custom or Bedrock model ID selectable even if the CLI does not list it.
                if let s = selection, !models.contains(where: { $0.value == s || $0.resolvedModel == s }) {
                    Text(s).tag(Optional(s))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(title, systemImage: "cpu").labelStyle(.titleAndIcon)
        }
        .help("Model")
    }
}

struct EffortPicker: View {
    @Binding var selection: EffortLevel?
    let levels: [EffortLevel]

    var body: some View {
        Menu {
            Picker("Effort", selection: $selection) {
                Text("Default").tag(EffortLevel?.none)
                ForEach(levels, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(selection?.rawValue.capitalized ?? "Effort", systemImage: "gauge.with.dots.needle.50percent").labelStyle(.titleAndIcon)
        }
        .help("Reasoning effort")
    }
}

struct PermissionModePicker: View {
    @Binding var selection: PermissionMode

    var body: some View {
        Menu {
            Picker("Permissions", selection: $selection) {
                ForEach([PermissionMode.default, .acceptEdits, .plan, .auto, .dontAsk, .bypassPermissions], id: \.self) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(selection.label, systemImage: selection.symbol)
        }
        .help("Permission mode: \(selection.label)")
    }
}

/// Standard trailing inspector: session settings, context window, cost, MCP and tasks.
struct ThreadInspector: View {
    let thread: ThreadModel
    let connection: HostConnection
    @State private var usage: JSONValue?
    @State private var customModel = ""

    var body: some View {
        Form {
            Section("Context") {
                if let u = usage {
                    let total = u["totalTokens"]?.doubleValue ?? 0
                    let max = u["maxTokens"]?.doubleValue ?? u["rawMaxTokens"]?.doubleValue ?? 0
                    if max > 0 {
                        Gauge(value: min(total / max, 1)) {
                            Text("Context window")
                        } currentValueLabel: {
                            Text("\(Format.tokens(total)) of \(Format.tokens(max))")
                        }
                    }
                    ForEach(u["categories"]?.arrayValue ?? [], id: \.self) { c in
                        LabeledContent(c.string("name") ?? "", value: Format.tokens(c["tokens"]?.doubleValue ?? 0))
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Button("Refresh") { Task { await refresh() } }
            }
            Section("Cost") {
                LabeledContent("This thread", value: Format.cost(thread.totalCostUsd))
                if let last = thread.turns.last?.result {
                    LabeledContent("Last turn", value: Format.cost(last.totalCostUsd))
                    LabeledContent("Duration", value: Format.duration(last.durationMs / 1000))
                }
            }
            Section("Model") {
                LabeledContent("Current", value: thread.info?.model ?? "Default")
                TextField("Custom model ID", text: $customModel, prompt: Text("us.anthropic.claude-…"))
                    .onSubmit {
                        guard !customModel.isEmpty else { return }
                        Task { await connection.setModel(thread, customModel) }
                    }
            }
            if let info = thread.info {
                Section("Session") {
                    LabeledContent("Status", value: info.status.rawValue)
                    LabeledContent("Directory", value: info.cwd.abbreviatingHome)
                    if let v = info.claudeCodeVersion { LabeledContent("Claude Code", value: v) }
                    if let o = info.outputStyle { LabeledContent("Output style", value: o) }
                    LabeledContent("Thread ID") { Text(info.threadId).textSelection(.enabled).font(.caption.monospaced()) }
                }
                if let servers = info.mcpServers, !servers.isEmpty {
                    Section("MCP servers") {
                        ForEach(servers, id: \.name) { s in
                            LabeledContent(s.name, value: s.status)
                        }
                    }
                }
            }
            if !thread.tasks.isEmpty {
                Section("Tasks") {
                    ForEach(thread.tasks.values.sorted { $0.seq < $1.seq }, id: \.taskId) { t in
                        LabeledContent(t.description ?? t.taskId, value: t.status ?? t.event)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: thread.turns.count) { await refresh() }
    }

    private func refresh() async {
        usage = await connection.contextUsage(thread)
    }
}
