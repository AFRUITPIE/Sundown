import Testing
import TetherProtocol
@testable import TetherKit
@testable import TetherUI

@MainActor
@Suite
struct SubagentInspectorTests {
    @Test func nestedSubagentContentRoutesToOneInspectorEntry() {
        let thread = ThreadModel.sampleToolCalls()

        let entries = inspectorTaskEntries(thread: thread)
        let entry = entries.first { $0.id == "tool-subagent-explore" }

        #expect(entry?.call?.kind == .subagent)
        #expect(thread.children(of: "tool-subagent-explore").count == 2)
        #expect(thread.rows.contains { row in
            if case .item(.toolCall(let call)) = row { return call.id == "tool-subagent-explore" }
            return false
        })
        #expect(!thread.rows.contains { row in
            thread.children(of: "tool-subagent-explore").contains { $0.id == row.id }
        })
    }

    @Test func taskLifecycleEnrichesTheMatchingInspectorEntry() {
        let thread = ThreadModel.sampleToolCalls()
        thread.apply(.taskEvent(.init(
            threadId: thread.id,
            seq: 20,
            event: "progress",
            taskId: "task-explore",
            toolUseId: "tool-subagent-explore",
            description: "Find every SwiftUI view",
            status: "running",
            summary: "Reading view files",
            data: [:]
        )))

        let entry = inspectorTaskEntries(thread: thread).first { $0.id == "tool-subagent-explore" }

        #expect(entry?.task?.taskId == "task-explore")
        #expect(entry?.task?.summary == "Reading view files")
        #expect(entry.map { SubagentLifecycle.title(call: $0.call!, task: $0.task) } == "Agent running")
    }

    @Test func terminalLifecycleUsesQuietChatSummaries() {
        let thread = ThreadModel.sampleToolCalls()
        guard let call = inspectorTaskEntries(thread: thread)
            .first(where: { $0.id == "tool-subagent-explore" })?.call else {
            Issue.record("Missing subagent fixture")
            return
        }
        let completed = TaskEventNotification(
            threadId: thread.id, seq: 21, event: "updated", taskId: "task-explore",
            toolUseId: call.id, description: nil, status: "completed", summary: nil, data: [:]
        )

        #expect(SubagentLifecycle.title(call: call, task: completed) == "Agent finished")
        #expect(!SubagentLifecycle.isRunning(call: call, task: completed))
    }

    @Test func backgroundSnapshotUpdatesTheChatAndInspectorLifecycle() {
        let thread = ThreadModel.sampleToolCalls()
        thread.apply(.taskEvent(.init(
            threadId: thread.id,
            seq: 20,
            event: "started",
            taskId: "task-explore",
            toolUseId: "tool-subagent-explore",
            description: "Find every SwiftUI view",
            status: "running",
            summary: nil,
            data: [:]
        )))
        thread.apply(.taskBackgroundChanged(.init(
            threadId: thread.id,
            seq: 21,
            tasks: [[
                "task_id": "task-explore",
                "task_type": "local_agent",
                "description": "Find every SwiftUI view"
            ]]
        )))

        guard let entry = inspectorTaskEntries(thread: thread)
            .first(where: { $0.id == "tool-subagent-explore" }), let call = entry.call else {
            Issue.record("Missing subagent fixture")
            return
        }

        #expect(entry.isBackgrounded)
        #expect(SubagentLifecycle.title(
            call: call,
            task: entry.task,
            isBackgrounded: entry.isBackgrounded
        ) == "Agent running in background")
    }
}
