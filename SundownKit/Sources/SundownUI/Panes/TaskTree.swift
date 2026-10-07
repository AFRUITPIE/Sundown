import Foundation
import SundownKit
import TetherProtocol

/// The chat's tasks as the Tasks tab browses them: each with what it is, how it stands and how long
/// it has run, under the task that started it. Built from `ThreadModel.taskEntries`, the SDK's task
/// events and the calls that started them.
struct TaskNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case workflow, agent, command, monitor, mcpTool
        /// A job that wakes the chat later (/loop, CronCreate, ScheduleWakeup).
        case schedule
        /// A /goal Claude works toward until it's met.
        case goal
        /// One the SDK names that this app doesn't know yet, in its own words.
        case other(String)

        var name: String {
            switch self {
            case .workflow: "Workflow"
            case .agent: "Agent"
            case .command: "Command"
            case .monitor: "Monitor"
            case .mcpTool: "MCP Tool"
            case .schedule: "Schedule"
            case .goal: "Goal"
            case .other(let name): name
            }
        }
    }

    enum State: Equatable {
        case running, waiting, done, failed, stopped
    }

    let id: String
    let title: String
    let kind: Kind
    let state: State
    let entry: InspectorTaskEntry
    /// The call that started it: a subagent's own, or the one that started a command or tool.
    var call: Item.ToolCall?
    /// When it started, for a running task's time.
    var started: Date?
    /// How long it took, once it's finished, when the SDK said.
    var seconds: Double?
    var children: [TaskNode] = []
    /// A workflow's run, for a workflow and for each of its agents.
    var workflow: WorkflowRun?
    /// One of a workflow's agents: no task of its own, so nothing to stop or background on its own.
    var agent: WorkflowRun.Agent?
    /// The phase a workflow's agent ran in, for its column's sections.
    var phase: String?
    var phaseIndex: Int?
    /// What its row says in place of a time: a schedule's how often or when next, a goal's checks.
    var note: String?

    /// The task Stop stops: a running task's own, or a running workflow's (found after a reload in
    /// its launch receipt). Never a workflow agent's: the CLI can't stop one alone.
    var stoppableTaskID: String? {
        guard agent == nil else { return nil }
        if entry.isTaskRunning, let task = entry.task { return task.taskId }
        if let workflow, workflow.isRunning { return workflow.taskId }
        return nil
    }

    /// A task started by another: its call's parent, or for a task with no call of its own, the
    /// parent of the call that started it (a command an agent ran in the background). A workflow
    /// agent's own task, whose call the chat never has, goes under that agent once the daemon knows
    /// which it was, else under its workflow; one whose workflow isn't listed (or a subagent's whose
    /// call isn't held) isn't listed either, never at the top.
    static func tree(_ entries: [InspectorTaskEntry], call: (String) -> Item.ToolCall?) -> [TaskNode] {
        var nodes: [String: TaskNode] = [:]
        var order: [String] = []
        var parents: [String: String] = [:]
        // A workflow agent's own task's agent, by entry id, and the subagents' tasks with nowhere to go.
        var agentOf: [String: String] = [:]
        var unplaced = Set<String>()
        // Which entry a call id belongs to: a subagent's own call, or the call that started a task.
        var entryByCall: [String: String] = [:]
        for entry in entries {
            if let id = entry.call?.id { entryByCall[id] = entry.id }
            if let id = entry.task?.toolUseId, entryByCall[id] == nil { entryByCall[id] = entry.id }
        }
        for entry in entries {
            let started = entry.call ?? entry.task?.toolUseId.flatMap(call)
            nodes[entry.id] = node(entry, startedBy: started)
            order.append(entry.id)
            if let parentCall = started?.parentToolUseId, let parent = entryByCall[parentCall], parent != entry.id {
                parents[entry.id] = parent
            } else if let task = entry.task, task.isOwnedBySubagent, started == nil {
                if let workflowCall = task.workflowToolUseId, let workflow = entryByCall[workflowCall], workflow != entry.id {
                    parents[entry.id] = workflow
                    if let agent = task.workflowAgentId { agentOf[entry.id] = agent }
                } else {
                    unplaced.insert(entry.id)
                }
            }
        }
        // Children first, so each parent takes its children complete; a parent missing from the
        // list leaves its children at the top.
        func attach(_ id: String) -> TaskNode {
            var node = nodes[id]!
            var children = order.filter { parents[$0] == id }
            var agents = agents(of: node)
            for i in agents.indices {
                guard let agentId = agents[i].agent?.agentId else { continue }
                let own = children.filter { agentOf[$0] == agentId }
                guard !own.isEmpty else { continue }
                agents[i].children = sorted(own.map(attach))
                children.removeAll { own.contains($0) }
            }
            node.children = sorted(children.map(attach)) + agents
            return node
        }
        return sorted(order.filter { !unplaced.contains($0) && (parents[$0] == nil || nodes[parents[$0]!] == nil) }.map(attach))
    }

    /// The path of ids from a top-level task down to `id`, for showing a task asked for by id.
    static func path(to id: String, in nodes: [TaskNode]) -> [String]? {
        for node in nodes {
            if node.id == id { return [id] }
            if let rest = path(to: id, in: node.children) { return [node.id] + rest }
        }
        return nil
    }

    /// A workflow's agents, by phase in the phases' order (any in no phase first), and within each,
    /// what's still going first, each in the order it started.
    static func agents(of node: TaskNode) -> [TaskNode] {
        guard node.kind == .workflow, node.agent == nil, let run = node.workflow else { return [] }
        let order = Dictionary(run.phases.enumerated().map { ($1.index, $0) }, uniquingKeysWith: { a, _ in a })
        let children = run.agents.map { agent in
            var child = TaskNode(id: "\(node.id)/agent/\(agent.index)", title: agent.label, kind: .agent,
                                 state: State(agent.state), entry: node.entry)
            child.workflow = run
            child.agent = agent
            child.phaseIndex = agent.phaseIndex
            child.phase = agent.phaseTitle
            child.started = agent.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if child.state != .running, let ms = agent.durationMs { child.seconds = ms / 1000 }
            return child
        }
        let phases = Dictionary(grouping: children) { $0.phaseIndex.map { order[$0] ?? Int.max } ?? -1 }
        return phases.keys.sorted().flatMap { sorted(phases[$0]!) }
    }

    /// A column's tasks in sections by the phase they ran in, when they're a workflow's agents in
    /// more than one phase; else one section with no title. Agents in no phase (which `agents(of:)`
    /// puts first) are a section with no title, never an empty header.
    static func phaseSections(_ nodes: [TaskNode]) -> [(id: Int, title: String?, nodes: [TaskNode])] {
        var sections: [(id: Int, title: String?, nodes: [TaskNode])] = []
        for node in nodes {
            let id = node.agent == nil ? -1 : node.phaseIndex ?? -1
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

    private static func node(_ entry: InspectorTaskEntry, startedBy call: Item.ToolCall?) -> TaskNode {
        if let run = entry.schedule {
            var node = TaskNode(id: entry.id, title: run.title, kind: .schedule, state: State(run.state), entry: entry)
            node.note = ScheduleText.note(run)
            return node
        }
        if let goal = entry.goal {
            var node = TaskNode(id: entry.id, title: goal.condition, kind: .goal, state: State(goal.state), entry: entry)
            node.note = GoalText.checks(goal)
            return node
        }
        let task = entry.task
        let data = task?.data ?? .null
        // A workflow by its name, never the latest agent's words.
        let title = entry.workflow?.name ?? task?.description ?? entry.call?.input.string("description") ?? entry.call?.summary
            ?? data["workflow_name"]?.stringValue ?? task?.taskId ?? "Task"
        var node = TaskNode(id: entry.id, title: title, kind: kind(entry, call: call), state: state(entry), entry: entry)
        node.call = call
        node.workflow = entry.workflow
        node.started = call.flatMap { $0.createdAt > 0 ? Date(timeIntervalSince1970: $0.createdAt / 1000) : nil }
        if let run = entry.workflow, node.state != .running, let ms = run.durationMs {
            node.seconds = ms / 1000
        } else if let ms = data["usage"]?["duration_ms"]?.doubleValue, node.state != .running {
            node.seconds = ms / 1000
        } else if let seconds = entry.call?.elapsedSeconds, node.state != .running {
            node.seconds = seconds
        }
        return node
    }

    private static func kind(_ entry: InspectorTaskEntry, call: Item.ToolCall?) -> Kind {
        if entry.workflow != nil || entry.call?.isWorkflow == true { return .workflow }
        switch entry.task?.data["task_type"]?.stringValue {
        case "local_workflow": return .workflow
        case "local_agent", "remote_agent": return .agent
        case "local_bash": return .command
        case "monitor", "monitor_mcp": return .monitor
        case "mcp_task": return .mcpTool
        case let type?: return .other(type.humanized)
        case nil:
            switch call?.kind {
            case .subagent: return .agent
            case .bash: return .command
            case .mcp: return .mcpTool
            default: return .other("Task")
            }
        }
    }

    private static func state(_ entry: InspectorTaskEntry) -> State {
        if let run = entry.workflow, entry.task == nil || run.status != .running {
            switch run.status {
            case .running: return .running
            case .failed: return .failed
            case .stopped: return .stopped
            case .completed: return .done
            // Neither running nor known to have ended (a run only its journal tells of): gray, not
            // a green "done" it may not be.
            case .unknown: return .waiting
            }
        }
        if entry.isGoing {
            return entry.task?.status == "pending" ? .waiting : .running
        }
        let ended = (entry.task?.status ?? entry.task?.event ?? entry.call?.status.rawValue ?? "").lowercased()
        if ended.contains("fail") || ended.contains("error") { return .failed }
        if ended.contains("stop") || ended.contains("interrupt") || ended.contains("kill") { return .stopped }
        return .done
    }
}

extension TaskNode.State {
    /// Running while it's scheduled; stopped once deleted or gone with its session.
    init(_ state: ScheduleRun.State) {
        switch state {
        case .scheduled: self = .running
        case .done: self = .done
        case .deleted, .ended: self = .stopped
        }
    }

    init(_ state: GoalRun.State) {
        switch state {
        case .active: self = .running
        case .met: self = .done
        case .failed: self = .failed
        case .cleared: self = .stopped
        }
    }

    init(_ state: WorkflowRun.Agent.State) {
        switch state {
        case .running: self = .running
        case .waiting: self = .waiting
        case .done: self = .done
        case .failed: self = .failed
        case .stopped: self = .stopped
        }
    }
}

extension TaskEventNotification {
    /// Started by a subagent (a workflow agent's background command): said on its every event by
    /// the daemon, and by the CLI on its start.
    var isOwnedBySubagent: Bool { ownedBySubagent == true || data["owned_by_subagent"]?.boolValue == true }
}

extension InspectorTaskEntry {
    /// Still running, in the background or not.
    var isGoing: Bool { isBackgrounded || SubagentLifecycle.isRunning(call: call, task: task) }
}
