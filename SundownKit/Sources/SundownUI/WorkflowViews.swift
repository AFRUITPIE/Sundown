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
    /// The workflow's task (`ThreadModel.callTasks`). Nil for a call the daemon has said nothing of
    /// yet, which reads as its call says.
    let task: TaskState?
    @Environment(\.windowRef) private var windowRef

    private var isRunning: Bool { task.map { $0.status == .running } ?? (call.status == .running || call.status == .pending) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { windowRef.window?.inspectSubagent(call.id) } label: {
                DisclosureRowLabel(expanded: false) { header }
            }
            .help(task?.workflow?.description ?? "Show in Tasks")
            .buttonStyle(.plain)
            .accessibilityLabel { label in
                label
                Text(statusWords)
            }
            .accessibilityHint("Shows the workflow in Tasks")
            .accessibilityIdentifier("transcript.toolCall")
            .contextMenu { menu }
            if let caption { RowNote(caption).monospacedDigit() }
        }
    }

    private var header: some View {
        let verb = ToolCallText.verb(call, workflow: task)
        let object = ToolCallText.object(call, workflow: task)
        return HStack(spacing: 6) {
            if isRunning {
                // Live while the run goes on, whatever the turn is doing. How far it's got is in
                // Tasks, which the row opens: the chat only says that it's running.
                ActivityLabel(text: object.isEmpty ? verb : "\(verb) \(object)", live: true)
            } else {
                Text(verb)
                if !object.isEmpty {
                    Text(object).lineLimit(1).truncationMode(.middle)
                }
                switch task?.status {
                case .failed?: StatusGlyph("exclamationmark.circle")
                case .stopped?: StatusGlyph("stop.circle")
                default: EmptyView()
                }
            }
        }
        .transcriptLine()
    }

    /// Under the row: why a run didn't finish, in gray. What it did is in Tasks.
    private var caption: String? {
        if call.status == .denied { return "Denied" }
        guard let task else { return nil }
        switch task.status {
        case .failed:
            let reason = (task.error ?? ToolCallText.reason(call) ?? "")
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return reason.isEmpty || reason == "Failed" ? "Failed" : "Failed: \(reason)"
        case .stopped: return "Stopped"
        default: return nil
        }
    }

    private var statusWords: String {
        switch task?.status {
        case .running?: "Running"
        case .failed?: "Failed"
        case .stopped?: "Stopped"
        case .done?: "Finished"
        default: isRunning ? "Running" : ""
        }
    }

    /// Also the workflow's detail's controls in Tasks (Copy Script, Stop): a menu is never the only
    /// way to a command.
    @ViewBuilder private var menu: some View {
        Button("Show in Tasks") { windowRef.window?.inspectSubagent(call.id) }
        if let script = call.workflowScript {
            Button("Copy Script") { Clipboard.copy(script) }
        }
        if let task, task.status == .running, let taskId = task.taskId {
            Divider()
            Button("Stop Workflow") { windowRef.window?.stopTask(taskId) }
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

/// How a workflow's run reads in the Tasks tab, from its task and its agents'. Pure, so it's tested
/// without a view.
enum WorkflowText {
    /// The phase being worked on: the latest running agent's, else the latest agent's.
    static func currentPhase(_ workflow: TaskState, agents: [TaskState]) -> TaskPhase? {
        let agent = agents.last { $0.status == .running } ?? agents.last
        guard let index = agent?.workflowAgent?.phaseIndex else { return nil }
        return workflow.workflow?.phases.first { $0.index == index }
    }

    /// How far it has got, while it runs: "Verify: 3 of 4 agents done", or "Starting" before any
    /// agent.
    static func progress(_ workflow: TaskState, agents: [TaskState]) -> String {
        guard !agents.isEmpty else { return "Starting" }
        let done = agents.count { $0.status == .done }
        let count = inflected("\(done) of ^[\(agents.count) agent](inflect: true) done")
        guard (workflow.workflow?.phases.count ?? 0) > 1, let phase = currentPhase(workflow, agents: agents),
              !phase.title.isEmpty else { return count }
        return "\(phase.title): \(count)"
    }

    /// What it used, in words: "4 agents · 98,951 tokens · 23 tool uses · 43s".
    static func usage(_ workflow: TaskState, agents: [TaskState]) -> String {
        var parts: [String] = []
        if !agents.isEmpty { parts.append(inflected("^[\(agents.count) agent](inflect: true)")) }
        if let tokens = workflow.usage?.totalTokens, tokens > 0 {
            parts.append(inflected("^[\(Int(tokens)) token](inflect: true)"))
        }
        if let uses = workflow.usage?.toolUses, uses > 0 { parts.append(inflected("^[\(Int(uses)) tool use](inflect: true)")) }
        if let ms = workflow.usage?.durationMs, ms > 0 { parts.append(Format.duration(ms / 1000)) }
        return parts.joined(separator: " · ")
    }

    private static func inflected(_ text: String.LocalizationValue) -> String {
        String(AttributedString(localized: text).characters)
    }
}

/// A workflow on its own in the Tasks tab: what it's for, what it used, and once it has finished,
/// what it returned. Never its script or launch receipt, nor how each phase stands: the column of
/// its agents beside it says that, in a section per phase.
struct WorkflowReport: View {
    let workflow: TaskState
    let agents: [TaskState]

    private var isRunning: Bool { workflow.status == .running }

    var body: some View {
        let info = workflow.workflow
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let description = info?.description, !description.isEmpty, description != info?.name {
                    Text(description).textSelection(.enabled)
                }
                if isRunning {
                    ActivityLabel(text: info?.activity ?? WorkflowText.progress(workflow, agents: agents), live: true)
                }
                let usage = WorkflowText.usage(workflow, agents: agents)
                if !usage.isEmpty {
                    Text(usage).foregroundStyle(.secondary).monospacedDigit()
                }
                if workflow.status == .failed, let error = workflow.error, !error.isEmpty {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let result = info?.result, !result.isEmpty, !isRunning {
                    WorkflowResultView(text: result)
                } else if !isRunning, agents.isEmpty, info?.description == nil {
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
/// replies, read from the agent's own transcript (`workflow/agentItems`, its prompt already without
/// the harness's framing), again whenever the daemon says the agent's state changed, at most once a
/// second. Its rows are folded when its items or the folding change, not per body.
/// Before the agent has an id, or from a host that can't read it, what its task says: its prompt,
/// its latest tool, its result.
struct WorkflowAgentTranscript: View {
    let thread: ThreadModel
    let connection: HostConnection
    let agent: TaskState
    /// The run it belongs to.
    let runId: String?
    @State private var items: [Item]?
    @State private var rows: [TranscriptRow] = []
    @State private var failure: String?
    @State private var attempt = 0
    @State private var lastFetch: ContinuousClock.Instant?
    @Environment(\.appearance) private var appearance

    private var running: Bool { agent.isGoing }

    /// Read again when the agent's state changes, or Try Again is pressed.
    private struct FetchKey: Equatable {
        let agent: TaskState
        let attempt: Int
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
        .task(id: FetchKey(agent: agent, attempt: attempt)) { await fetch() }
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
                        case .toolGroup(let calls, _): ToolCallGroupView(calls: calls, thread: thread, rowID: row.id)
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
        guard let tool = agent.workflowAgent?.lastToolName else { return nil }
        return tool == "StructuredOutput" ? "Returning its result" : tool
    }

    /// The task's words, while there's no transcript to show.
    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let prompt = agent.workflowAgent?.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if running {
                    ActivityLabel(text: activity ?? (agent.status == .waiting ? "Waiting for an agent slot" : "Starting"), live: true)
                }
                if let result = agent.output, !result.isEmpty {
                    MarkdownView(text: result).frame(maxWidth: .infinity, alignment: .leading)
                }
                if agent.status == .failed, let error = agent.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !running {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure ?? (agent.workflowAgent?.agentId == nil ? "This agent’s transcript isn’t available." : "Loading transcript…"))
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
        guard let agentId = agent.workflowAgent?.agentId, let runId else { return }
        if let lastFetch {
            let wait = .seconds(1) - (ContinuousClock.now - lastFetch)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        guard !Task.isCancelled else { return }
        lastFetch = .now
        do {
            let read = try await connection.workflowAgentItems(thread, runId: runId, agentId: agentId, finished: !running)
            guard !Task.isCancelled else { return }
            if read != items {
                items = read
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
#Preview("Workflow rows (running, finished)") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach([true, false], id: \.self) { running in
            let thread = ThreadModel.sampleWorkflow(running: running)
            let call = thread.call("workflow-call")!
            WorkflowCallView(call: call, task: thread.callTasks[call.id])
        }
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
