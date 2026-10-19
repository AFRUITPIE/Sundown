import SundownKit
import TetherProtocol

// Test-only views of the enums' cases, so a test can `try #require` one rather than `guard case`.

extension Item {
    public var toolCall: ToolCall? { if case .toolCall(let call) = self { call } else { nil } }
    public var agentMessage: AgentMessage? { if case .agentMessage(let message) = self { message } else { nil } }
}

extension TranscriptRow {
    public var item: Item? { if case .item(let item) = self { item } else { nil } }
    public var toolGroup: [Item.ToolCall]? { if case .toolGroup(let calls, _) = self { calls } else { nil } }
    public var turnWork: (rows: [TranscriptRow], durationMs: Double?)? {
        if case .turnWork(_, let rows, let durationMs) = self { (rows, durationMs) } else { nil }
    }
}

extension ServerRequest {
    public var permissionRequest: PermissionRequestParams? { if case .permissionRequest(let p) = self { p } else { nil } }
    public var unknown: (method: String, params: JSONValue)? { if case .unknown(let method, let params) = self { (method, params) } else { nil } }
}

extension ServerNotification {
    public var itemAgentMessageDelta: ItemAgentMessageDeltaNotification? {
        if case .itemAgentMessageDelta(let delta) = self { delta } else { nil }
    }
    public var unknown: (method: String, params: JSONValue)? { if case .unknown(let method, let params) = self { (method, params) } else { nil } }
}

extension HostConnection.State {
    public var failure: String? { if case .failed(let message) = self { message } else { nil } }
}

// MARK: Item builders

/// A prompt and a reply at `ms`, for tests that fold or place items by time.
public func prompt(_ id: String, at ms: Double = 1_000) -> Item {
    .userMessage(.init(id: id, createdAt: ms, content: [.text(.init(text: "go"))]))
}

public func reply(_ id: String, at ms: Double = 2_000) -> Item {
    .agentMessage(.init(id: id, createdAt: ms, text: "done"))
}

/// Items placed in minutes from a Monday morning, so a script's gaps and day changes are the date
/// separators' own: prompts, replies, commands, edits and subagents.
public protocol TimedItems {}

extension TimedItems {
    public var t0: Double { 1_790_000_000_000 }

    public func at(_ minutes: Double) -> Double { t0 + minutes * 60_000 }

    public func prompt(_ id: String, _ minutes: Double, synthetic: Bool? = nil) -> Item {
        .userMessage(.init(id: id, createdAt: at(minutes), content: [.text(.init(text: "Prompt \(id), with more words after it"))],
                           synthetic: synthetic))
    }

    public func reply(_ id: String, _ minutes: Double, text: String = "Done.", parent: String? = nil) -> Item {
        .agentMessage(.init(id: id, parentToolUseId: parent, createdAt: at(minutes), text: text))
    }

    public func call(_ id: String, _ minutes: Double, kind: ToolKind = .bash, status: ToolStatus = .completed,
                     parent: String? = nil) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: at(minutes), name: "Bash", kind: kind,
                        input: ["command": .string("echo \(id)")], status: status))
    }

    public func edit(_ id: String, _ minutes: Double, path: String = "/repo/a.swift", status: ToolStatus = .completed,
                     parent: String? = nil) -> Item {
        // With its change once finished, as the daemon sends it.
        .toolCall(Item.ToolCall(id: id, parentToolUseId: parent, createdAt: at(minutes), name: "Edit", kind: .fileEdit,
                                input: ["file_path": .string(path), "old_string": "one\ntwo\nthree",
                                        "new_string": .string("one\n\(id)\nthree\nfour")],
                                status: status).withComparedEdit)
    }

    public func subagent(_ id: String, _ minutes: Double, status: ToolStatus) -> Item {
        .toolCall(.init(id: id, createdAt: at(minutes), name: "Task", kind: .subagent,
                        input: ["description": "Look around"], status: status))
    }
}

// A chat with no tasks, as most tests' are: reads and subscriptions say so.

extension ThreadReadResult {
    public init(items: [Item], turns: [Turn], summary: ThreadSummary? = nil, historySeq: Int? = nil, hasMore: Bool? = nil) {
        self.init(items: items, turns: turns, summary: summary, historySeq: historySeq, hasMore: hasMore, tasks: [])
    }
}

extension ThreadSubscribeResult {
    public init(thread: ThreadInfo, replayed: Int, gap: Bool) {
        self.init(thread: thread, replayed: replayed, gap: gap, tasks: [])
    }
}
