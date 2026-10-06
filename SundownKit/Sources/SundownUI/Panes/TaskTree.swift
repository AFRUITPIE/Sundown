import Foundation
import SundownKit
import TetherProtocol

/// The chat's tasks as the Tasks tab browses them: each with what it is, how it stands and how long
/// it has run, under the task that started it. Built from `ThreadModel.taskEntries`, the SDK's task
/// events and the calls that started them.
struct TaskNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case workflow, agent, command, monitor, mcpTool
        /// One the SDK names that this app doesn't know yet, in its own words.
        case other(String)

        var name: String {
            switch self {
            case .workflow: "Workflow"
            case .agent: "Agent"
            case .command: "Command"
            case .monitor: "Monitor"
            case .mcpTool: "MCP Tool"
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

    /// A task started by another: its call's parent, or for a task with no call of its own, the
    /// parent of the call that started it (a command an agent ran in the background).
    static func tree(_ entries: [InspectorTaskEntry], call: (String) -> Item.ToolCall?) -> [TaskNode] {
        var nodes: [String: TaskNode] = [:]
        var order: [String] = []
        var parents: [String: String] = [:]
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
            }
        }
        // Children first, so each parent takes its children complete; a parent missing from the
        // list leaves its children at the top.
        func attach(_ id: String) -> TaskNode {
            var node = nodes[id]!
            node.children = sorted(order.filter { parents[$0] == id }.map(attach))
            return node
        }
        return sorted(order.filter { parents[$0] == nil || nodes[parents[$0]!] == nil }.map(attach))
    }

    /// The path of ids from a top-level task down to `id`, for showing a task asked for by id.
    static func path(to id: String, in nodes: [TaskNode]) -> [String]? {
        for node in nodes {
            if node.id == id { return [id] }
            if let rest = path(to: id, in: node.children) { return [node.id] + rest }
        }
        return nil
    }

    /// What's still going first, then what's finished, each in the order it started.
    private static func sorted(_ nodes: [TaskNode]) -> [TaskNode] {
        nodes.filter { $0.state == .running || $0.state == .waiting } + nodes.filter { $0.state != .running && $0.state != .waiting }
    }

    private static func node(_ entry: InspectorTaskEntry, startedBy call: Item.ToolCall?) -> TaskNode {
        let task = entry.task
        let data = task?.data ?? .null
        let title = task?.description ?? entry.call?.input.string("description") ?? entry.call?.summary
            ?? data["workflow_name"]?.stringValue ?? task?.taskId ?? "Task"
        var node = TaskNode(id: entry.id, title: title, kind: kind(entry, call: call), state: state(entry), entry: entry)
        node.call = call
        node.started = call.map { Date(timeIntervalSince1970: $0.createdAt / 1000) }
        if let ms = data["usage"]?["duration_ms"]?.doubleValue, node.state != .running {
            node.seconds = ms / 1000
        } else if let seconds = entry.call?.elapsedSeconds, node.state != .running {
            node.seconds = seconds
        }
        return node
    }

    private static func kind(_ entry: InspectorTaskEntry, call: Item.ToolCall?) -> Kind {
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
        if entry.isGoing {
            return entry.task?.status == "pending" ? .waiting : .running
        }
        let ended = (entry.task?.status ?? entry.task?.event ?? entry.call?.status.rawValue ?? "").lowercased()
        if ended.contains("fail") || ended.contains("error") { return .failed }
        if ended.contains("stop") || ended.contains("interrupt") || ended.contains("kill") { return .stopped }
        return .done
    }
}

extension InspectorTaskEntry {
    /// Still running, in the background or not.
    var isGoing: Bool { isBackgrounded || SubagentLifecycle.isRunning(call: call, task: task) }
}
