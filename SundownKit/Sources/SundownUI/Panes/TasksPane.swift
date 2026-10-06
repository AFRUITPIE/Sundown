import SwiftUI
import SundownKit

/// The subagents and workflows this chat has started. Reads `thread.taskEntries`, which is stored
/// and rebuilt only on task events, so streamed message deltas never touch this pane. A task's
/// detail replaces the list, with its own back button: not a `NavigationStack`, whose Back button
/// went to the window's toolbar, over the chat, rather than over the pane.
struct TasksPane: View {
    let thread: ThreadModel
    let connection: HostConnection
    @Binding var selectedTaskID: String?

    var body: some View {
        let entries = thread.taskEntries
        if let selectedTaskID, let entry = entries.first(where: { $0.id == selectedTaskID }) {
            InspectorTaskDetail(entry: entry, thread: thread, connection: connection) { self.selectedTaskID = nil }
        } else if entries.isEmpty {
            PaneEmptyState("No Tasks", symbol: WindowTab.tasks.symbol)
        } else {
            // What's still going on top; what's finished in a group of its own below.
            let finished = entries.filter { !$0.isGoing }
            Form {
                let going = entries.filter(\.isGoing)
                if !going.isEmpty {
                    Section { rows(going) }
                }
                if !finished.isEmpty {
                    Section("Finished") { rows(finished) }
                }
            }
        }
    }
}

extension TasksPane {
    private func rows(_ entries: [InspectorTaskEntry]) -> some View {
        ForEach(entries) { entry in
            Button { selectedTaskID = entry.id } label: {
                TaskRow(entry: entry)
            }
            .buttonStyle(.plain)
        }
    }
}

extension InspectorTaskEntry {
    /// Still running, in the background or not.
    var isGoing: Bool { isBackgrounded || SubagentLifecycle.isRunning(call: call, task: task) }
}

/// One subagent or workflow run: what it is, and whether it's still going, with the sidebar's dot.
struct TaskRow: View {
    let entry: InspectorTaskEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // The dot on the title's line, the status line under the title, as in the sidebar.
                HStack(alignment: .firstTextBaseline, spacing: ChatStatusDot.spacing) {
                    ChatStatusDot(state: state)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(entry.task?.description ?? entry.call?.summary
                         ?? entry.call?.input.string("description") ?? entry.task?.taskId ?? "Task")
                        .lineLimit(2)
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, ChatStatusDot.gutter)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        // The status line says it in words; the dot is for the eye.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.task?.description ?? entry.call?.summary ?? "Task"))
        .accessibilityValue(statusText)
    }

    private var state: ChatState {
        if entry.isGoing { return .working }
        let ended = (entry.task?.status ?? entry.task?.event ?? entry.call?.status.rawValue ?? "").lowercased()
        if ended.contains("fail") || ended.contains("error") { return .failed }
        if ended.contains("stop") || ended.contains("interrupt") || ended.contains("kill") { return .stopped }
        return .idle
    }

    private var statusText: String {
        if entry.isBackgrounded { return "Running in background" }
        guard let call = entry.call else {
            // A lifecycle event with no call of ours: the server's own word for it, in plain English.
            return (entry.task?.status ?? entry.task?.event ?? "Task").humanized
        }
        return SubagentLifecycle.title(call: call, task: entry.task, isBackgrounded: entry.isBackgrounded)
    }

}

/// One task on its own: how it's going, what it was asked, and what it has done so far.
struct InspectorTaskDetail: View {
    let entry: InspectorTaskEntry
    let thread: ThreadModel
    let connection: HostConnection
    let close: () -> Void

    var body: some View {
            Form {
                // Unheaded: a "Status" section whose first row is "Status" says it twice.
                Section {
                    if let call = entry.call {
                        LabeledContent(
                            "Status",
                            value: SubagentLifecycle.title(
                                call: call,
                                task: entry.task,
                                isBackgrounded: entry.isBackgrounded
                            )
                        )
                        if let seconds = call.elapsedSeconds {
                            LabeledContent("Elapsed", value: Format.duration(seconds))
                        }
                    } else if let task = entry.task {
                        LabeledContent("Status", value: entry.isBackgrounded
                            ? "Running in background"
                            : (task.status ?? task.event).humanized)
                    }
                    if let summary = entry.task?.summary, !summary.isEmpty {
                        Text(summary).lineLimit(nil).textSelection(.enabled)
                    }
                    if entry.isTaskRunning, let task = entry.task {
                        HStack {
                            // Only the chat's own command or agent, while it still holds up its turn.
                            if entry.canMoveToBackground, let toolUseId = task.toolUseId, thread.isTopLevelCall(toolUseId) {
                                Button("Move to Background") {
                                    Task { await connection.moveToBackground(thread, toolUseId: toolUseId) }
                                }
                            }
                            Button("Stop Task", role: .destructive) {
                                Task { await connection.stopTask(thread, taskId: task.taskId) }
                            }
                        }
                    }
                }
                if let prompt = entry.call?.input.string("prompt"), !prompt.isEmpty {
                    Section("Prompt") {
                        Text(prompt).lineLimit(nil).textSelection(.enabled)
                    }
                }
                if let toolUseId = entry.call?.id {
                    let children = thread.children(of: toolUseId)
                    if !children.isEmpty {
                        Section("Activity") {
                            ForEach(children, id: \.id) { ItemView(item: $0, thread: thread) }
                        }
                    } else if let output = entry.call?.outputText, !output.isEmpty {
                        Section("Result") {
                            Text(output).lineLimit(nil).textSelection(.enabled)
                        }
                    }
                }
            }
            // Back to the list, over the task, which scrolls under it.
            .safeAreaBar(edge: .top) {
                HStack {
                    Button("All Tasks", systemImage: "chevron.left", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    Text(entry.task?.description ?? entry.call?.input.string("description") ?? "Task")
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
    }
}

#if DEBUG
#Preview("Tasks") {
    @Previewable @State var selection: String?
    panePreview {
        TasksPane(thread: .sampleWithTasks(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

#Preview("Tasks (empty)") {
    @Previewable @State var selection: String?
    panePreview {
        TasksPane(thread: .sampleIdleChat(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

#Preview("Tasks (subagent detail)") {
    // Live, so All Tasks goes back to the list in the canvas.
    @Previewable @State var selection: String? = "tool-subagent-explore"
    panePreview {
        TasksPane(thread: .sampleToolCalls(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

/// A task still running: it can be stopped from here.
#Preview("Tasks (running task detail)") {
    @Previewable @State var selection: String? = "task:task-1"
    panePreview {
        TasksPane(thread: .sampleWithTasks(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

/// Every shape a row can take, at the inspector's width: running, finished, failed, backgrounded.
#Preview("TaskRow") {
    Form {
        Section {
            ForEach(ThreadModel.sampleWithTasks().taskEntries) { TaskRow(entry: $0) }
        }
    }
    .formStyle(.grouped)
    .lineLimit(1)
    .frame(width: 300, height: 260)
}
#endif

#if DEBUG

// A design preview of the Tasks tab as a view of its own: a sidebar of tasks, and a detail that
// suits each kind (an agent's activity, a command's output, a workflow's phases and agents). Mock
// data only; nothing in the app uses this yet.

private enum MockKind: String { case agent, shell, workflow
    var symbol: String {
        switch self {
        case .agent: "sparkles"
        case .shell: "terminal"
        case .workflow: "point.3.connected.trianglepath.dotted"
        }
    }
    var tint: Color {
        switch self {
        case .agent: .purple
        case .shell: .gray
        case .workflow: .indigo
        }
    }
}

private enum MockStatus { case running, done, failed, stopped
    var state: ChatState {
        switch self {
        case .running: .working
        case .done: .idle
        case .failed: .failed
        case .stopped: .stopped
        }
    }
}

private struct MockTask: Identifiable, Hashable {
    let id: String
    let kind: MockKind
    let name: String
    let detail: String
    let status: MockStatus
    let elapsed: String
    var background = false
}

private let mockTasks: [MockTask] = [
    .init(id: "w1", kind: .workflow, name: "Review the diff for correctness", detail: "Workflow · 5 of 9 agents done",
          status: .running, elapsed: "3m 02s", background: true),
    .init(id: "a1", kind: .agent, name: "Find every SwiftUI view in SundownUI", detail: "Explore · 18 tools",
          status: .running, elapsed: "1m 40s", background: true),
    .init(id: "s1", kind: .shell, name: "swift test --package-path SundownKit", detail: "Command · in background",
          status: .running, elapsed: "52s", background: true),
    .init(id: "a2", kind: .agent, name: "Research macOS text selection", detail: "General · 4 tools",
          status: .done, elapsed: "6m 11s"),
    .init(id: "s2", kind: .shell, name: "xcodebuild -scheme Sundown build", detail: "Command · exit 65",
          status: .failed, elapsed: "2m 03s"),
    .init(id: "a3", kind: .agent, name: "Audit AGENTS.md against the code", detail: "Explore · stopped",
          status: .stopped, elapsed: "40s"),
]

// MARK: Sidebar

private struct TaskSidebar: View {
    @Binding var selection: String?

    var body: some View {
        // Plain stacks in the mock: a sidebar List crashed the preview agent.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header("Running")
                ForEach(mockTasks.filter { $0.status == .running }) { row($0) }
                header("Finished").padding(.top, 10)
                ForEach(mockTasks.filter { $0.status != .running }) { row($0) }
            }
            .padding(10)
        }
        .background(.background.secondary)
        .safeAreaInset(edge: .bottom) {
            // What's at work, at a glance: the sidebar's own footer.
            HStack(spacing: 6) {
                ChatStatusDot(state: .working)
                Text("3 running · 2 in the background").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func row(_ task: MockTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: task.kind.symbol)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(task.kind.tint.gradient, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name).lineLimit(1)
                Text("\(task.detail) · \(task.elapsed)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            ChatStatusDot(state: task.status.state)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(selection == task.id ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { selection = task.id }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
    }
}

// MARK: Detail header

private struct DetailHeader: View {
    let task: MockTask
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(task.kind.tint.gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        ChatStatusDot(state: task.status.state)
                        Text(task.status == .running ? "Running" : task.status == .done ? "Done" : task.status == .failed ? "Failed" : "Stopped")
                        Text("·").foregroundStyle(.tertiary)
                        Text(task.elapsed).monospacedDigit()
                        if task.background {
                            Text("·").foregroundStyle(.tertiary)
                            Label("In the Background", systemImage: "moon.zzz").labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if task.status == .running {
                    ControlGroup {
                        Button("Open in Chat", systemImage: "text.bubble") {}
                        Button("Stop", systemImage: "stop.fill") {}
                    }
                    .fixedSize()
                }
            }
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear).tint(task.kind.tint)
            }
        }
        .padding(20)
    }
}

// MARK: Workflow detail

private struct MockAgent: Identifiable {
    let id = UUID()
    let name: String
    let doing: String
    let status: MockStatus
    let tokens: String
}

private struct MockPhase: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let agents: [MockAgent]
}

private let mockPhases: [MockPhase] = [
    .init(title: "Review", detail: "Each dimension reads the diff", agents: [
        .init(name: "review: bugs", doing: "3 findings", status: .done, tokens: "41K"),
        .init(name: "review: performance", doing: "2 findings", status: .done, tokens: "38K"),
        .init(name: "review: accessibility", doing: "Reading MarkdownText.swift", status: .running, tokens: "22K"),
    ]),
    .init(title: "Verify", detail: "Each finding checked on its own", agents: [
        .init(name: "verify: stale marker widths", doing: "Confirmed", status: .done, tokens: "12K"),
        .init(name: "verify: empty table cells", doing: "Confirmed", status: .done, tokens: "9K"),
        .init(name: "verify: undo after send", doing: "Running a test", status: .running, tokens: "15K"),
        .init(name: "verify: Esc in popovers", doing: "Not a bug", status: .done, tokens: "7K"),
    ]),
    .init(title: "Report", detail: "Ranked and written up", agents: [
        .init(name: "report", doing: "Waiting for Verify", status: .stopped, tokens: "—"),
    ]),
]

private struct WorkflowDetail: View {
    let task: MockTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(task: task, progress: 5.0 / 9)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(mockPhases.enumerated()), id: \.element.id) { index, phase in
                        PhaseView(number: index + 1, phase: phase, isLast: index == mockPhases.count - 1)
                    }
                }
                .padding(20)
            }
        }
    }
}

/// A phase: a step on a timeline, its agents as rows beside it.
private struct PhaseView: View {
    let number: Int
    let phase: MockPhase
    let isLast: Bool

    private var done: Int { phase.agents.filter { $0.status == .done }.count }
    private var running: Bool { phase.agents.contains { $0.status == .running } }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The timeline: a numbered node, a line on to the next phase.
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(done == phase.agents.count ? AnyShapeStyle(.green) : running ? AnyShapeStyle(.blue) : AnyShapeStyle(.quaternary))
                    if done == phase.agents.count {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.caption.bold()).foregroundStyle(running ? .white : .secondary)
                    }
                }
                .frame(width: 24, height: 24)
                if !isLast { Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(phase.title).font(.headline)
                    Text(phase.detail).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(done) of \(phase.agents.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(spacing: 0) {
                    ForEach(Array(phase.agents.enumerated()), id: \.element.id) { i, agent in
                        if i > 0 { Divider().padding(.leading, 34) }
                        AgentRow(agent: agent)
                    }
                }
                .background(.fill.quinary, in: .rect(cornerRadius: 10))
            }
            .padding(.bottom, isLast ? 0 : 4)
        }
    }
}

private struct AgentRow: View {
    let agent: MockAgent

    var body: some View {
        HStack(spacing: 10) {
            // Done is a check; waiting is an empty ring; running pulses as the sidebar's dot does.
            Group {
                switch agent.status {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .stopped: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .running: ChatStatusDot(state: .working)
                }
            }
            .frame(width: 14)
            Text(agent.name)
            Text(agent.doing)
                .foregroundStyle(agent.status == .running ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .italic(agent.status == .running)
                .lineLimit(1)
            Spacer()
            Text(agent.tokens).font(.callout).foregroundStyle(.tertiary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(.rect)
    }
}

// MARK: Agent and command details

private struct AgentDetail: View {
    let task: MockTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(task: task)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    // The facts in a row of small figures, as Activity Monitor's inspector does.
                    HStack(spacing: 28) {
                        figure("Tool Calls", "18")
                        figure("Tokens", "64K")
                        figure("Model", "Sonnet")
                        figure("Started", "2:14 PM")
                    }
                    DisclosureGroup("Prompt") {
                        Text("Find every SwiftUI view in SundownUI and list which read `thread.items`.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Activity").font(.headline).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        activity("Searched code", "rg -n 'thread.items' SundownUI")
                        activity("Read 6 files", "TranscriptView.swift, ItemViews.swift, …")
                        Text("Most views read `rows`, not `items`. Two exceptions so far:")
                        activity("Reading", "ToolCallView.swift", running: true)
                    }
                }
                .padding(20)
            }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }

    private func activity(_ verb: String, _ what: String, running: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(verb).foregroundStyle(.secondary)
            Text(what).foregroundStyle(.secondary).lineLimit(1)
            if running { ProgressView().controlSize(.mini) }
        }
        .font(.callout)
    }
}

private struct CommandDetail: View {
    let task: MockTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(task: task)
            Divider()
            ScrollView {
                Text("""
                Building for debugging...
                [42/88] Compiling SundownUI MarkdownText.swift
                [43/88] Compiling SundownUI Composer.swift
                Test Suite 'MarkdownTextTests' started
                ✔ Test everyCharacterHasAStyle() passed
                ✔ Test copyIsPlainText() passed
                """)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(.fill.quinary)
            // Follows the output's end, as a terminal does.
            .defaultScrollAnchor(.bottom)
        }
    }
}

// MARK: The view

private struct TasksViewDesign: View {
    @State var selection: String? = "w1"

    var body: some View {
        HStack(spacing: 0) {
            TaskSidebar(selection: $selection)
                .frame(width: 280)
            Divider()
            Group {
                switch mockTasks.first(where: { $0.id == selection }) {
                case let task? where task.kind == .workflow: WorkflowDetail(task: task)
                case let task? where task.kind == .shell: CommandDetail(task: task)
                case let task?: AgentDetail(task: task)
                case nil: ContentUnavailableView("No Task Selected", systemImage: "square.stack.3d.up")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview("Tasks · workflow", traits: .fixedLayout(width: 1100, height: 720)) {
    TasksViewDesign(selection: "w1")
}

#Preview("Tasks · agent", traits: .fixedLayout(width: 1100, height: 720)) {
    TasksViewDesign(selection: "a1")
}

#Preview("Tasks · command", traits: .fixedLayout(width: 1100, height: 720)) {
    TasksViewDesign(selection: "s1")
}
#endif
