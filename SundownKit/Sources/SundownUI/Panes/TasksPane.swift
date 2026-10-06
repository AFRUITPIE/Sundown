import Charts
import SwiftUI
import SundownKit
import TetherProtocol

/// The chat's tasks (subagents, commands, workflows, monitors, MCP tools), browsed in columns as
/// Finder browses: each column the tasks started by the one selected to its left, and the last the
/// selected task itself. Reads `thread.taskEntries`, which is stored and rebuilt only on task
/// events, so streamed message deltas don't reach the columns; an agent's detail is its own
/// transcript, which follows its items as they stream.
struct TasksPane: View {
    let thread: ThreadModel
    let connection: HostConnection
    /// The task shown, kept by the window so a subagent row in the chat can open it here.
    @Binding var selectedTaskID: String?
    /// What's selected in each column, left to right.
    @State private var path: [String] = []
    /// Each column's width, as its divider was dragged to.
    @State private var widths: [Int: CGFloat] = [:]
    @State private var position = ScrollPosition(edge: .trailing)

    private static let firstWidth: CGFloat = 250
    private static let width: CGFloat = 210
    private static let detailMinimum: CGFloat = 360

    var body: some View {
        let tree = TaskNode.tree(thread.taskEntries, call: thread.call)
        if tree.isEmpty {
            PaneEmptyState("No Tasks", symbol: WindowTab.tasks.symbol)
        } else {
            let columns = columns(tree)
            let columnsWidth = columns.indices.map(width).reduce(0, +)
            // As Finder's browser: the columns and the detail scroll sideways once they don't fit,
            // the detail at least its minimum and otherwise the rest of the width.
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, nodes in
                        column(nodes, index: index, of: index == 0 ? nil : node(at: index - 1, in: tree))
                            .frame(width: width(index))
                        ColumnDivider(width: Binding(get: { width(index) }, set: { widths[index] = $0 }))
                    }
                    detail(selected(in: tree))
                        .containerRelativeFrame(.horizontal) { width, _ in
                            max(Self.detailMinimum, width - columnsWidth - CGFloat(columns.count))
                        }
                }
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.trailing)
            // A new column scrolls into view, as Finder's does.
            .onChange(of: path) {
                withAnimation(.snappy) { position.scrollTo(edge: .trailing) }
                if path.last != selectedTaskID { selectedTaskID = path.last }
            }
            // A task asked for from the chat opens with the tasks that lead to it.
            .onChange(of: selectedTaskID, initial: true) {
                guard let id = selectedTaskID, path.last != id else { return }
                if let found = TaskNode.path(to: id, in: tree) { path = found }
            }
            // A workflow with no live task (after a reload, or run by another client) is read.
            .task {
                for run in thread.workflowsToRead { await connection.loadWorkflow(thread, toolUseId: run.toolUseId) }
            }
        }
    }

    private func width(_ index: Int) -> CGFloat { widths[index] ?? (index == 0 ? Self.firstWidth : Self.width) }

    /// The top-level tasks, then the tasks started by each selected one that started some.
    private func columns(_ tree: [TaskNode]) -> [[TaskNode]] {
        var result = [tree]
        for id in path {
            guard let node = result.last?.first(where: { $0.id == id }), !node.children.isEmpty else { break }
            result.append(node.children)
        }
        return result
    }

    /// The task selected in column `index`.
    private func node(at index: Int, in tree: [TaskNode]) -> TaskNode? {
        var nodes = tree
        var found: TaskNode?
        for id in path.prefix(index + 1) {
            guard let node = nodes.first(where: { $0.id == id }) else { return nil }
            found = node
            nodes = node.children
        }
        return found
    }

    private func selected(in tree: [TaskNode]) -> TaskNode? {
        path.isEmpty ? nil : node(at: path.count - 1, in: tree)
    }

    private func column(_ nodes: [TaskNode], index: Int, of parent: TaskNode?) -> some View {
        let selection = Binding<String?>(
            get: { path.indices.contains(index) ? path[index] : nil },
            set: { id in
                path = Array(path.prefix(index))
                if let id { path.append(id) }
            })
        let sections = TaskNode.phaseSections(nodes)
        return List(selection: selection) {
            // No section headers but a workflow's phases: each row's dot says how it stands, and
            // the order keeps what's still going first.
            if sections.count > 1 {
                ForEach(sections, id: \.id) { section in
                    Section(section.title ?? "") {
                        ForEach(section.nodes) { TaskNodeRow(node: $0).tag($0.id) }
                    }
                }
            } else {
                ForEach(nodes) { TaskNodeRow(node: $0).tag($0.id) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // What this column holds, named, over a bar of how it's going (its counts in its help),
        // and Stop for the task that started them, beside both.
        .safeAreaBar(edge: .top) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(parent?.title ?? "Tasks")
                        .font(.headline)
                        .lineLimit(1)
                        .help(parent?.title ?? "Tasks")
                        .accessibilityAddTraits(.isHeader)
                    TaskStatusBar(states: nodes.map(\.state))
                }
                if let parent, let taskId = parent.stoppableTaskID {
                    TaskStopButton { Task { await connection.stopTask(thread, taskId: taskId) } }
                        .controlSize(.large)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    @ViewBuilder private func detail(_ node: TaskNode?) -> some View {
        if let node {
            TaskDetail(node: node, thread: thread, connection: connection)
                // Each task starts at its own end, with its own scroll.
                .id(node.id)
        } else {
            PaneEmptyState("No Task Selected", symbol: WindowTab.tasks.symbol)
        }
    }
}

/// A task's row: its dot on its name's line, as the sidebar's chats have theirs; what it is and how
/// long it has run, or took, under the name.
struct TaskNodeRow: View {
    let node: TaskNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChatStatusDot.spacing) {
            TaskStateDot(state: node.state)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).lineLimit(1)
                HStack {
                    Text(node.kind.name)
                    Spacer(minLength: 8)
                    TaskTime(node: node)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(node.children.isEmpty ? 0 : 1)
                .accessibilityHidden(true)
        }
        // Names run long; the whole one is a hover away.
        .help(node.title)
        .accessibilityElement(children: .combine)
    }
}

/// How long a task has run, counting while it runs, or how long it took.
struct TaskTime: View {
    let node: TaskNode

    var body: some View {
        if node.state == .running, let started = node.started {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.duration(max(0, context.date.timeIntervalSince(started))))
            }
            .monospacedDigit()
        } else if let seconds = node.seconds {
            Text(Format.duration(seconds)).monospacedDigit()
        }
    }
}

/// The sidebar's dot, with one for every state, so each row says how it stands: blue and pulsing
/// while it runs, red if it failed, a ring if it was stopped, green once done, gray while waiting.
struct TaskStateDot: View {
    let state: TaskNode.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state {
            case .running:
                Image(systemName: "circle.fill").resizable().foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            case .failed: Circle().fill(.red)
            case .stopped: Circle().strokeBorder(.secondary, lineWidth: 1.5)
            case .done: Circle().fill(.green)
            case .waiting: Circle().fill(.quaternary)
            }
        }
        .frame(width: ChatStatusDot.size, height: ChatStatusDot.size)
        .accessibilityLabel(state.word.capitalized)
    }
}

extension TaskNode.State {
    /// How a count of them reads: "2 failed".
    var word: String {
        switch self {
        case .running: "running"
        case .waiting: "waiting"
        case .done: "finished"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    var style: AnyShapeStyle {
        switch self {
        case .running: AnyShapeStyle(.blue)
        case .waiting: AnyShapeStyle(.quaternary)
        case .done: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.red)
        case .stopped: AnyShapeStyle(.gray)
        }
    }
}

/// How many tasks are finished, failed, running, stopped and waiting, as one bar in the dots'
/// colors, its counts in its help and for VoiceOver. A stacked Swift Charts bar, as the Context
/// breakdown draws its categories.
struct TaskStatusBar: View {
    let states: [TaskNode.State]
    private static let order: [TaskNode.State] = [.done, .failed, .running, .stopped, .waiting]

    var body: some View {
        let counts = Self.order.map { state in (state, states.filter { $0 == state }.count) }.filter { $0.1 > 0 }
        let summary = counts.map { "\($0.1) \($0.0.word)" }.joined(separator: ", ")
        Chart(counts, id: \.0) { state, count in
            BarMark(x: .value("Count", count), stacking: .standard)
                .foregroundStyle(state.style)
        }
        .chartXScale(domain: 0...max(states.count, 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.quaternary.opacity(0.5)) }
        .clipShape(.capsule)
        .frame(height: 6)
        .help(summary)
        .accessibilityElement()
        .accessibilityLabel(summary)
    }
}

/// Stop, as the composer's: a glass circle with the stop symbol.
struct TaskStopButton: View {
    let action: () -> Void

    var body: some View {
        Button("Stop", systemImage: "stop.fill", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Stop")
            // The header around it may use a smaller text style; Stop keeps the detail's size.
            .font(.body)
    }
}

/// A column's divider, which drags to resize the column before it, as Finder's do.
private struct ColumnDivider: View {
    @Binding var width: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let from = start ?? width
                            start = from
                            width = min(max(from + value.translation.width, 150), 520)
                        }
                        .onEnded { _ in start = nil })
            }
            .accessibilityHidden(true)
    }
}

/// One task on its own: its name and actions across the top, and below, what suits it: an agent's
/// transcript, a command's output, what a workflow or tool reported.
struct TaskDetail: View {
    let node: TaskNode
    let thread: ThreadModel
    let connection: HostConnection

    var body: some View {
        content
            .safeAreaBar(edge: .top) {
                HStack(alignment: .firstTextBaseline) {
                    Text(node.title)
                        .font(.title3).fontWeight(.semibold)
                        .lineLimit(2)
                        .help(node.title)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 12)
                    // Controls, so glass, at the composer's size.
                    HStack {
                        if node.agent == nil, node.entry.canMoveToBackground, let toolUseId = node.entry.task?.toolUseId,
                           thread.isTopLevelCall(toolUseId) {
                            Button("Move to Background") {
                                Task { await connection.moveToBackground(thread, toolUseId: toolUseId) }
                            }
                        }
                        // A task with tasks of its own is stopped from above its column.
                        if node.children.isEmpty, let taskId = node.stoppableTaskID {
                            TaskStopButton { Task { await connection.stopTask(thread, taskId: taskId) } }
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .fixedSize()
                }
                .scenePadding(.horizontal)
                .padding(.vertical, 8)
            }
    }

    @ViewBuilder private var content: some View {
        if let agent = node.agent, let run = node.workflow {
            WorkflowAgentTranscript(thread: thread, connection: connection, run: run, agent: agent)
        } else if node.kind == .workflow, let run = node.workflow {
            WorkflowReport(run: run, thread: thread, connection: connection)
        } else if node.kind == .agent, let call = node.call {
            SubagentTranscript(thread: thread, call: call, running: node.state == .running)
        } else {
            TaskReport(node: node)
        }
    }
}

/// An agent's run as the chat draws one: its prompt, then its calls folded and its replies, in the
/// transcript's own rows, following them as they stream.
private struct SubagentTranscript: View {
    let thread: ThreadModel
    let call: Item.ToolCall
    let running: Bool
    @Environment(\.appearance) private var appearance

    var body: some View {
        let children = thread.children(of: call.id)
        // Its prompt, in a bubble as a prompt is: what the agent was asked.
        let prompt: [Item] = call.input.string("prompt").map {
            [.userMessage(.init(id: "prompt-\(call.id)", createdAt: call.createdAt, content: [.text(.init(text: $0))]))]
        } ?? []
        let rows = foldTranscriptRows(prompt + children, grouping: appearance.toolCalls.folding != .everyCall, live: running)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows, id: \.id) { TranscriptRowView(row: $0, thread: thread) }
                if running, children.isEmpty {
                    ActivityLabel(text: "Starting", live: true)
                }
            }
            .scaledFont(.body)
            .padding(.vertical, 16)
            .readingColumn()
        }
        .accessibilityLabel("Transcript")
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
    }
}

/// What a task that isn't an agent's run has to show: what it ran, what it said last, and its
/// output, as text that scrolls sideways rather than wrapping.
private struct TaskReport: View {
    let node: TaskNode

    var body: some View {
        let entry = node.entry
        let command = node.call?.input.string("command")
        let summary = entry.task?.summary
        let output = node.call?.outputText
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let command, command != node.title {
                    Text(command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let workflow = entry.task?.data["workflow_name"]?.stringValue, workflow != node.title {
                    LabeledContent("Workflow", value: workflow)
                }
                if let summary, !summary.isEmpty {
                    Text(summary).textSelection(.enabled)
                }
                if let output, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityLabel("Output")
                }
                if summary?.isEmpty ?? true, output?.isEmpty ?? true {
                    Text(node.state == .running ? "Nothing reported yet" : "Nothing reported")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding([.horizontal, .bottom])
            .padding(.top, 8)
        }
    }
}

#if DEBUG
#Preview("Tasks") {
    @Previewable @State var selection: String?
    panePreview {
        TasksPane(thread: .sampleWithTaskKinds(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

#Preview("Tasks (empty)") {
    @Previewable @State var selection: String?
    panePreview {
        TasksPane(thread: .sampleIdleChat(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

/// A subagent asked for from the chat: its column path opens to it, its transcript beside.
#Preview("Tasks (subagent)") {
    @Previewable @State var selection: String? = "tool-subagent-explore"
    panePreview {
        TasksPane(thread: .sampleToolCalls(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

/// A workflow's agents, by phase, and one agent's transcript beside them.
#Preview("Tasks (workflow)") {
    @Previewable @State var selection: String? = "workflow-call/agent/4"
    panePreview {
        TasksPane(thread: .sampleWorkflow(running: true), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

/// A finished workflow: its phases, what it used and what it returned.
#Preview("Tasks (workflow finished)") {
    @Previewable @State var selection: String? = "workflow-call"
    panePreview {
        TasksPane(thread: .sampleWorkflow(running: false), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}

/// A command an agent started, two columns in.
#Preview("Tasks (nested command)") {
    @Previewable @State var selection: String? = "task:bg-tests"
    panePreview {
        TasksPane(thread: .sampleWithTaskKinds(), connection: .sample(), selectedTaskID: $selection).paneStyle()
    }
}
#endif
