import Testing
import TetherProtocol
@testable import SundownKit
@testable import SundownUI

@MainActor
@Suite
struct SubagentInspectorTests {
    @Test func nestedSubagentContentRoutesToOneTask() {
        let thread = ThreadModel.sampleToolCalls()

        let task = thread.tasks.first { $0.id == "tool-subagent-explore" }

        #expect(task?.kind == .agent)
        #expect(thread.callTasks["tool-subagent-explore"] == task)
        #expect(thread.children(of: "tool-subagent-explore").count == 2)
        #expect(foldTranscriptRows(thread.topLevelItems).contains { row in
            if case .item(.toolCall(let call)) = row { return call.id == "tool-subagent-explore" }
            return false
        })
        #expect(!foldTranscriptRows(thread.topLevelItems).contains { row in
            thread.children(of: "tool-subagent-explore").contains { $0.id == row.id }
        })
    }

    /// The agent's row says how its task stands, as the daemon states it.
    @Test func theRowFollowsTheAgentsTask() throws {
        let thread = ThreadModel.sampleToolCalls()
        let call = try #require(thread.call("tool-subagent-explore"), "Missing subagent fixture")
        func state(_ status: TaskStatus, backgrounded: Bool? = nil) -> TaskState {
            TaskState(id: call.id, toolUseId: call.id, taskId: "task-explore", kind: .agent, title: "Find every SwiftUI view",
                      status: status, backgrounded: backgrounded)
        }
        #expect(SubagentLifecycle.title(call: call, task: thread.callTasks[call.id]) == "Agent running")
        thread.apply(.taskUpdated(.init(threadId: thread.id, seq: 20, task: state(.running, backgrounded: true))))
        #expect(SubagentLifecycle.title(call: call, task: thread.callTasks[call.id]) == "Agent running in background")
        #expect(thread.callTasks[call.id]?.isInBackground == true)
        thread.apply(.taskUpdated(.init(threadId: thread.id, seq: 21, task: state(.done, backgrounded: true))))
        #expect(SubagentLifecycle.title(call: call, task: thread.callTasks[call.id]) == "Agent finished")
        #expect(thread.callTasks[call.id]?.isInBackground == false)
        #expect(SubagentLifecycle.title(call: call, task: state(.failed)) == "Agent failed")
        #expect(SubagentLifecycle.title(call: call, task: state(.stopped)) == "Agent stopped")
        // With no task, the call says it.
        #expect(SubagentLifecycle.title(call: call, task: nil) == "Agent running")
    }
}
