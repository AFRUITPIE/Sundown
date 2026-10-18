import Foundation
import SundownKit
import TetherProtocol

/// The chat's tasks as the Tasks tab browses them: each under the task that started it, as the
/// daemon says (`TaskState.parentId`), with what it is, how it stands and how long it has run.
/// Built from `ThreadModel.tasks` and the calls that started them.
struct TaskNode: Identifiable, Equatable {
    enum State: Equatable {
        case running, waiting, done, failed, stopped

        init(_ status: TaskStatus) {
            switch status {
            case .running: self = .running
            case .done: self = .done
            case .failed: self = .failed
            case .stopped: self = .stopped
            // Waiting, or a status this app doesn't know yet: gray, not a green "done" it may not be.
            default: self = .waiting
            }
        }
    }

    let task: TaskState
    /// The call that started it: a subagent's own, or the one that started a command or tool.
    var call: Item.ToolCall?
    var children: [TaskNode] = []
    /// The run a workflow agent belongs to, for its transcript: its own, else its workflow's.
    var runId: String?

    var id: String { task.id }
    var title: String { task.title }
    var state: State { State(task.status) }
    var isWorkflow: Bool { task.kind == .workflow }
    /// One of a workflow's agents: no task of the CLI's, so nothing to stop or background on its own.
    var isWorkflowAgent: Bool { task.kind == .workflowAgent }

    /// What it is, under its name.
    var kindName: String {
        switch task.kind {
        case .workflow: "Workflow"
        case .agent, .workflowAgent: "Agent"
        case .command: "Command"
        case .monitor: "Monitor"
        case .mcpTool: "MCP Tool"
        case .schedule: "Schedule"
        case .goal: "Goal"
        default: task.taskType?.humanized ?? "Task"
        }
    }

    /// When it started, for a running task's time.
    var started: Date? {
        if let ms = task.startedAt, ms > 0 { return Date(timeIntervalSince1970: ms / 1000) }
        return call.flatMap { $0.createdAt > 0 ? Date(timeIntervalSince1970: $0.createdAt / 1000) : nil }
    }

    /// How long it took, once it's finished, when that's known.
    var seconds: Double? {
        guard state != .running else { return nil }
        if let ms = task.usage?.durationMs, ms > 0 { return ms / 1000 }
        if let start = task.startedAt, let end = task.endedAt, end > start { return (end - start) / 1000 }
        return call?.elapsedSeconds
    }

    /// What its row says in place of a time: a schedule's how often or when next, a goal's checks.
    var note: String? {
        if let schedule = task.schedule { return ScheduleText.note(task, schedule) }
        if let goal = task.goal { return GoalText.checks(goal) }
        return nil
    }

    /// The task Stop stops: a running task's own, or one waiting to start (a workflow's stops its
    /// agents too). Never a workflow agent's: the CLI can't stop one alone; nor a workflow said to
    /// be waiting, which is one only its files tell of, not known to be going.
    var stoppableTaskID: String? {
        guard !isWorkflowAgent, task.status == .running || (task.status == .waiting && !isWorkflow) else { return nil }
        return task.taskId
    }

    /// The tasks under the ones that started them, what's still going first. A workflow's agents
    /// come after its other children, by phase. A task whose parent isn't listed is at the top.
    static func tree(_ tasks: [TaskState], call: (String) -> Item.ToolCall?) -> [TaskNode] {
        let ids = Set(tasks.map(\.id))
        var children: [String: [TaskState]] = [:]
        var top: [TaskState] = []
        for task in tasks {
            if let parent = task.parentId, parent != task.id, ids.contains(parent) {
                children[parent, default: []].append(task)
            } else {
                top.append(task)
            }
        }
        func node(_ task: TaskState, runId: String?) -> TaskNode {
            var made = TaskNode(task: task, call: task.toolUseId.flatMap(call))
            made.runId = task.workflowAgent?.runId ?? runId
            let own = children[task.id] ?? []
            let run = task.workflow?.runId ?? made.runId
            let agents = own.filter { $0.kind == .workflowAgent }.map { node($0, runId: run) }
            let others = own.filter { $0.kind != .workflowAgent }.map { node($0, runId: run) }
            made.children = sorted(others) + byPhase(agents, phases: task.workflow?.phases ?? [])
            return made
        }
        return sorted(top.map { node($0, runId: nil) })
    }

    /// The path of ids from a top-level task down to `id`, for showing a task asked for by id.
    static func path(to id: String, in nodes: [TaskNode]) -> [String]? {
        for node in nodes {
            if node.id == id { return [id] }
            if let rest = path(to: id, in: node.children) { return [node.id] + rest }
        }
        return nil
    }

    /// A workflow's agents by phase in the phases' order (any in no phase first), and within each,
    /// what's still going first, each in the order it started.
    private static func byPhase(_ agents: [TaskNode], phases: [TaskPhase]) -> [TaskNode] {
        let order = Dictionary(phases.enumerated().map { ($1.index, $0) }, uniquingKeysWith: { a, _ in a })
        let grouped = Dictionary(grouping: agents) { $0.phaseIndex.map { order[$0] ?? Int.max } ?? -1 }
        return grouped.keys.sorted().flatMap { sorted(grouped[$0]!) }
    }

    /// The phase a workflow's agent ran in, for its column's sections.
    var phaseIndex: Int? { task.workflowAgent?.phaseIndex }
    var phase: String? { task.workflowAgent?.phase }

    /// A column's tasks in sections by the phase they ran in, when they're a workflow's agents in
    /// more than one phase; else one section with no title. Agents in no phase (which come first)
    /// are a section with no title, never an empty header.
    static func phaseSections(_ nodes: [TaskNode]) -> [(id: Int, title: String?, nodes: [TaskNode])] {
        var sections: [(id: Int, title: String?, nodes: [TaskNode])] = []
        for node in nodes {
            let id = node.isWorkflowAgent ? node.phaseIndex ?? -1 : -1
            if let last = sections.indices.last, sections[last].id == id {
                sections[last].nodes.append(node)
            } else {
                let title = id == -1 ? nil : node.phase.flatMap { $0.isEmpty ? nil : $0 } ?? "Phase \(id)"
                sections.append((id, title, [node]))
            }
        }
        guard sections.count > 1 else { return [(-1, nil, nodes)] }
        return sections
    }

    /// What's still going first, then what's finished, each in the order it started.
    private static func sorted(_ nodes: [TaskNode]) -> [TaskNode] {
        nodes.filter { $0.state == .running || $0.state == .waiting } + nodes.filter { $0.state != .running && $0.state != .waiting }
    }
}
