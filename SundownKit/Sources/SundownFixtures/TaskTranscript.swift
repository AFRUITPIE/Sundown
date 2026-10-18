import Foundation
import TetherProtocol
import SundownKit

/// The `tasks` scenario's chat: a workflow that has finished (`WorkflowSample`, its result a
/// message of its own before the next prompt), then an agent that started an agent and a
/// background command, a monitor and an MCP tool, as the SDK reports them, running and finished;
/// and messages the person didn't type (Claude Code's, another session's, a compaction's summary).
/// A second chat holds the same items, followed rather than live, as most of a host's chats are.
/// Times as seconds before now, and the calls the task scenarios (`TaskTranscript`,
/// `ShowcaseTranscript.reviewItems`) and the Tasks previews are made of.
struct TaskClock {
    let now = Date().timeIntervalSince1970 * 1000

    func ago(_ seconds: Double) -> Double { now - seconds * 1000 }

    func call(_ id: String, _ name: String, _ kind: ToolKind, _ input: JSONValue, status: ToolStatus = .completed,
              output: String? = nil, parent: String? = nil, at seconds: Double) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: ago(seconds), name: name, kind: kind, input: input,
                        status: status, outputText: output))
    }
}

enum TaskTranscript {
    static let followedChat = ThreadSummary(threadId: "tasks-followed", title: "Followed Tasks", cwd: "/tmp/sundown-fixture",
                                            updatedAt: 1_699_999_999_000, status: .notLoaded)

    /// When the workflow ran: before the rest of the chat.
    static var workflowNow: Double { Date().timeIntervalSince1970 * 1000 - 500_000 }

    static func items() -> [Item] {
        let clock = TaskClock()
        let root = "/tmp/sundown-fixture/Sources/"
        return WorkflowSample.items(now: workflowNow, running: false) + [
            .userMessage(.init(id: "tasks-user", createdAt: clock.ago(400),
                               content: [.text(.init(text: "Review the changes, and find which views read thread.items."))])),
            clock.call("agent-1", "Task", .subagent, [
                "subagent_type": "Explore", "description": "Find every SwiftUI view",
                "prompt": "Find every SwiftUI view and list which read `thread.items`.",
            ], status: .running, at: 100),
            clock.call("agent-1-grep", "Grep", .grep, ["pattern": "thread\\.items", "path": .string(root)],
                       output: "TranscriptFind.swift:88\nThreadView.swift:41", parent: "agent-1", at: 95),
            .agentMessage(.init(id: "agent-1-reply", parentToolUseId: "agent-1", createdAt: clock.ago(80),
                                text: "Most views read `rows`, not `items`. Two exceptions so far:\n\n- `TranscriptFind` builds its search text from items.\n- `ThreadView` reads the last item.")),
            clock.call("bg-call", "Bash", .bash, [
                "command": "swift test", "description": "Run the tests", "run_in_background": true,
            ], output: "Command running in background", parent: "agent-1", at: 70),
            clock.call("agent-2", "Task", .subagent, [
                "description": "Check how TranscriptFind reads items",
                "prompt": "Read TranscriptFind.swift and say how it builds its search text.",
            ], status: .running, parent: "agent-1", at: 34),
            clock.call("agent-2-read", "Read", .fileRead, ["file_path": .string(root + "TranscriptFind.swift")],
                       status: .running, parent: "agent-2", at: 5),
            clock.call("failed-call", "Bash", .bash, ["command": "xcodebuild -scheme Sundown build", "run_in_background": true],
                       output: "** BUILD FAILED **", at: 300),
            .compaction(.init(id: "tasks-compaction", createdAt: clock.ago(4), preTokens: 84_000)),
            .userMessage(.init(id: "tasks-summary", createdAt: clock.ago(4), content: [.text(.init(text:
                "This session is being continued from a previous conversation that ran out of context."))],
                               synthetic: true, origin: "compaction")),
            .userMessage(.init(id: "tasks-claude-code", createdAt: clock.ago(3), content: [.text(.init(text:
                "Caveat: the messages below were generated while running local commands."))], synthetic: true)),
            .userMessage(.init(id: "tasks-peer", createdAt: clock.ago(2), content: [.text(.init(text: "The release notes are drafted."))],
                               synthetic: true, origin: "peer", originName: "release-notes")),
        ]
    }

    /// The chat's tasks as the daemon sends them: the finished workflow's, two agents (one started
    /// by the other) and a background command the first started, a monitor, an MCP tool, and a
    /// build that failed.
    static func tasks() -> [TaskState] {
        let clock = TaskClock()
        return WorkflowSample.tasks(now: workflowNow, running: false) + [
            TaskState(id: "agent-1", toolUseId: "agent-1", taskId: "agent-task-1", kind: .agent, taskType: "local_agent",
                      title: "Find every SwiftUI view", status: .running, startedAt: clock.ago(100)),
            TaskState(id: "agent-2", parentId: "agent-1", toolUseId: "agent-2", taskId: "agent-task-2", kind: .agent,
                      taskType: "local_agent", title: "Check how TranscriptFind reads items", status: .running,
                      startedAt: clock.ago(34)),
            TaskState(id: "bg-call", parentId: "agent-1", toolUseId: "bg-call", taskId: "bg-tests", kind: .command,
                      taskType: "local_bash", title: "swift test", status: .running, startedAt: clock.ago(70), backgrounded: true),
            TaskState(id: "task:monitor-1", taskId: "monitor-1", kind: .monitor, taskType: "monitor",
                      title: "Watch CI on the pull request", status: .running, startedAt: clock.ago(60)),
            TaskState(id: "task:mcp-1", taskId: "mcp-1", kind: .mcpTool, taskType: "mcp_task", title: "Run all tests in Xcode",
                      status: .done, summary: "412 tests passed, 3 skipped.", usage: .init(durationMs: 243_000, toolUses: 1)),
            TaskState(id: "failed-call", toolUseId: "failed-call", taskId: "build-1", kind: .command, taskType: "local_bash",
                      title: "xcodebuild -scheme Sundown build", status: .failed, startedAt: clock.ago(300),
                      backgrounded: true, summary: "Build failed", usage: .init(durationMs: 123_000)),
        ]
    }
}
