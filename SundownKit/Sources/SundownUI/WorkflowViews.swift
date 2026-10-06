import SwiftUI
import SundownKit
import TetherProtocol

/// A dynamic workflow's row in the chat: what it is and how far it has got, opening it in the Tasks
/// tab, as a subagent's row does. Its call comes back at once (the run goes on in the background),
/// so its tense and its shimmer follow the run, not the call or the turn. No script and no launch
/// receipt: its agents and result are in the Tasks tab, and the result is the message it sends the
/// chat when it finishes.
struct WorkflowCallView: View {
    let call: Item.ToolCall
    /// The thread's run for the call (`ThreadModel.workflowRuns`). Nil only for a call the thread
    /// doesn't hold, which reads as its call says, never building a run (or reading its script) here.
    let run: WorkflowRun?
    @Environment(\.inspectSubagent) private var inspectSubagent
    @Environment(\.stopTask) private var stopTask

    private var isRunning: Bool { run?.isRunning ?? (call.status == .running || call.status == .pending) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { inspectSubagent(call.id) } label: {
                HStack(spacing: 6) {
                    header
                    DisclosureIndicator(expanded: false)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .help(run?.description ?? "Show in Tasks")
            .buttonStyle(.plain)
            .accessibilityLabel { label in
                label
                Text(statusWords)
            }
            .accessibilityHint("Shows the workflow in Tasks")
            .accessibilityIdentifier("transcript.toolCall")
            .contextMenu { menu }
            if let caption {
                Text(caption)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        }
    }

    private var header: some View {
        let verb = ToolCallText.verb(call, workflow: run)
        let object = ToolCallText.object(call, workflow: run)
        return HStack(spacing: 6) {
            if isRunning {
                // Live while the run goes on, whatever the turn is doing.
                ActivityLabel(text: object.isEmpty ? verb : "\(verb) \(object)", live: true)
                    .fontWeight(.medium)
                if let run {
                    Text(run.progressText)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            } else {
                Text(verb).foregroundStyle(.secondary).fontWeight(.medium)
                if !object.isEmpty {
                    Text(object).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                }
                switch run?.status {
                case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.tertiary).scaledFont(.caption)
                case .stopped: Image(systemName: "stop.circle").foregroundStyle(.tertiary).scaledFont(.caption)
                default: EmptyView()
                }
            }
        }
        .scaledFont(.callout)
    }

    /// Under the row: what a finished run did, or why it didn't finish, in gray.
    private var caption: String? {
        if call.status == .denied { return "Denied" }
        guard let run else { return nil }
        switch run.status {
        case .failed:
            let reason = (run.error ?? ToolCallText.reason(call) ?? "")
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return reason.isEmpty || reason == "Failed" ? "Failed" : "Failed: \(reason)"
        case .stopped: return "Stopped"
        case .completed:
            let caption = run.finishedCaption
            return caption.isEmpty ? nil : caption
        default: return nil
        }
    }

    private var statusWords: String {
        switch run?.status {
        case .running: "Running, \(run?.progressText ?? "")"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .completed: "Finished"
        case .unknown, nil: isRunning ? "Running" : ""
        }
    }

    /// Also the workflow's detail's controls in Tasks (Copy Script, Stop): a menu is never the only
    /// way to a command.
    @ViewBuilder private var menu: some View {
        Button("Show in Tasks") { inspectSubagent(call.id) }
        if let script = call.workflowScript {
            Button("Copy Script") { Clipboard.copy(script) }
        }
        if let run, run.isRunning, let taskId = run.taskId {
            Divider()
            Button("Stop Workflow") { stopTask(taskId) }
        }
    }
}

/// What a workflow returned: pretty-printed JSON as code when it is JSON, else Markdown as a reply.
struct WorkflowResultView: View {
    let text: String

    var body: some View {
        if let json = Self.prettyJSON(text) {
            CodeBlock(code: json, language: "JSON", lineLimit: 40)
        } else {
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The text, indented, when it's a JSON object or array.
    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A workflow on its own in the Tasks tab: what it's for, what it used, and once it has finished,
/// what it returned. Never its script or launch receipt, nor how each phase stands: the column of
/// its agents beside it says that, in a section per phase. `TasksPane` reads the run again while
/// it goes on.
struct WorkflowReport: View {
    let run: WorkflowRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let description = run.description, !description.isEmpty, description != run.name {
                    Text(description).textSelection(.enabled)
                }
                if run.isRunning {
                    ActivityLabel(text: run.activity ?? run.progressText, live: true)
                }
                let usage = run.usageText
                if !usage.isEmpty {
                    Text(usage).foregroundStyle(.secondary).monospacedDigit()
                }
                if run.status == .failed, let error = run.error, !error.isEmpty {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let result = run.result, !result.isEmpty, !run.isRunning {
                    WorkflowResultView(text: result)
                } else if !run.isRunning, run.agents.isEmpty, run.description == nil {
                    Text("Nothing reported").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding([.horizontal, .bottom])
            .padding(.top, 8)
        }
    }
}

/// One workflow agent's run, as the chat draws a subagent's: its prompt, its calls folded and its
/// replies, read from the agent's own transcript (`workflow/agentItems`), again as it goes on. Its
/// prompt is the script's task alone, without the harness's framing or the person's relayed
/// request (`WorkflowAgentPrompt`); its rows are folded when its items or the folding change, not
/// per body.
/// Before the agent has an id, or from a host that can't read it, what the run's snapshot says:
/// the start of its prompt, its latest tool, the start of its result.
struct WorkflowAgentTranscript: View {
    let thread: ThreadModel
    let connection: HostConnection
    let run: WorkflowRun
    let agent: WorkflowRun.Agent
    @State private var items: [Item]?
    @State private var rows: [TranscriptRow] = []
    @State private var failure: String?
    @State private var attempt = 0
    @State private var lastFetch: ContinuousClock.Instant?
    @Environment(\.appearance) private var appearance

    private var running: Bool { agent.state == .running || agent.state == .waiting }

    /// What changes when the agent does something: read again then.
    private var fetchKey: String {
        "\(agent.agentId ?? "")|\(agent.toolCalls ?? -1)|\(agent.lastProgressAt ?? 0)|\(agent.state)|\(attempt)"
    }

    private var grouping: Bool { appearance.toolCalls.folding != .everyCall }

    var body: some View {
        Group {
            if let items, !items.isEmpty {
                transcript
            } else {
                summary
            }
        }
        .task(id: fetchKey) { await fetch() }
        .onChange(of: grouping) { refold() }
        .onChange(of: running) { refold() }
    }

    private func refold() {
        rows = items.map { foldTranscriptRows($0, grouping: grouping, live: running) } ?? []
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows, id: \.id) { row in
                    // Its own values each read: these items aren't the thread's, so their rows
                    // aren't kept up to date by its boxes.
                    VStack(alignment: .leading, spacing: 0) {
                        switch row {
                        case .item(let item): ItemView(item: item, thread: thread)
                        case .toolGroup(let calls): ToolCallGroupView(calls: calls, thread: thread, rowID: row.id)
                        default: TranscriptRowView(row: row, thread: thread)
                        }
                    }
                }
                if running {
                    ActivityLabel(text: activity ?? "Working", live: true)
                }
            }
            .scaledFont(.body)
            .padding(.vertical, 16)
            .readingColumn()
        }
        .environment(\.offersChatActions, false)
        .accessibilityLabel("Transcript")
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
    }

    private var activity: String? {
        guard let tool = agent.lastToolName else { return nil }
        if tool == "StructuredOutput" { return "Returning its result" }
        guard let summary = agent.lastToolSummary, !summary.isEmpty else { return tool }
        return "\(tool) \(summary)"
    }

    /// The snapshot's words, while there's no transcript to show.
    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let prompt = agent.promptPreview, !prompt.isEmpty {
                    Text(prompt)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if running {
                    ActivityLabel(text: activity ?? (agent.state == .waiting ? "Waiting for an agent slot" : "Starting"), live: true)
                }
                if let result = agent.resultPreview, !result.isEmpty {
                    MarkdownView(text: result).frame(maxWidth: .infinity, alignment: .leading)
                }
                if agent.state == .failed, let error = agent.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !running {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure ?? (agent.agentId == nil ? "This agent’s transcript isn’t available." : "Loading transcript…"))
                            .foregroundStyle(.secondary)
                        if failure != nil {
                            Button("Try Again") { attempt += 1 }
                        }
                    }
                }
            }
            .scaledFont(.body)
            .padding(.vertical, 16)
            .readingColumn()
        }
    }

    /// Reads the agent's transcript, at most once a second, keeping what's shown meanwhile.
    private func fetch() async {
        guard let agentId = agent.agentId, let runId = run.runId else { return }
        if let lastFetch {
            let wait = .seconds(1) - (ContinuousClock.now - lastFetch)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        guard !Task.isCancelled else { return }
        lastFetch = .now
        do {
            let read = try await connection.workflowAgentItems(thread, runId: runId, agentId: agentId, finished: !running)
            guard !Task.isCancelled else { return }
            let unframed = WorkflowAgentPrompt.unframed(read)
            if unframed != items {
                items = unframed
                refold()
            }
            failure = read.isEmpty && !running ? "This agent’s transcript is empty." : nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("Workflow row (running)") {
    let thread = ThreadModel.sampleWorkflow(running: true)
    let call = thread.call("workflow-call")!
    VStack(alignment: .leading) {
        WorkflowCallView(call: call, run: thread.workflowRuns[call.id])
    }
    .padding()
    .frame(width: 560)
}

#Preview("Workflow row (finished)") {
    let thread = ThreadModel.sampleWorkflow(running: false)
    let call = thread.call("workflow-call")!
    VStack(alignment: .leading) {
        WorkflowCallView(call: call, run: thread.workflowRuns[call.id])
    }
    .padding()
    .frame(width: 560)
}

#Preview("Workflow result") {
    WorkflowResultView(text: #"{"findings": [{"file": "TaskTree.swift", "line": 45, "summary": "Workflow nodes never have children"}], "verified": 1}"#)
        .padding()
        .frame(width: 560)
}
#endif
