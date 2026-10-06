#if DEBUG
import Foundation
import Testing
import SundownKit
@testable import SundownUI

/// The Tasks tab's columns: each task under the one that started it, with what it is and how it stands.
@MainActor
@Suite
struct TaskTreeTests {
    private func tree() -> [TaskNode] {
        let thread = ThreadModel.sampleWithTaskKinds()
        return TaskNode.tree(thread.taskEntries, call: thread.call)
    }

    @Test func eachTaskIsUnderTheTaskThatStartedIt() {
        let top = tree()
        let agent = top.first { $0.id == "agent-1" }
        #expect(agent != nil)
        // The agent's own agent, and the command it ran in the background (a task with no call of
        // its own, found through the call that started it).
        #expect(Set(agent?.children.map(\.id) ?? []) == ["agent-2", "task:bg-tests"])
        #expect(!top.contains { $0.id == "agent-2" || $0.id == "task:bg-tests" })
    }

    @Test func kindsComeFromTheSDKsTaskType() {
        let all = flatten(tree())
        #expect(all["task:wf-1"]?.kind == .workflow)
        #expect(all["agent-1"]?.kind == .agent)
        #expect(all["task:bg-tests"]?.kind == .command)
        #expect(all["task:monitor-1"]?.kind == .monitor)
        #expect(all["task:mcp-1"]?.kind == .mcpTool)
    }

    @Test func runningComesFirstAndAFinishedTaskKeepsItsTime() {
        let top = tree()
        let firstFinished = top.firstIndex { $0.state != .running && $0.state != .waiting } ?? top.count
        #expect(top[..<firstFinished].allSatisfy { $0.state == .running })
        #expect(top[firstFinished...].allSatisfy { $0.state != .running })
        let mcp = flatten(top)["task:mcp-1"]
        #expect(mcp?.state == .done)
        #expect(mcp?.seconds == 243)
    }

    @Test func aPathLeadsToANestedTask() {
        #expect(TaskNode.path(to: "agent-2", in: tree()) == ["agent-1", "agent-2"])
        #expect(TaskNode.path(to: "missing", in: tree()) == nil)
    }

    private func flatten(_ nodes: [TaskNode]) -> [String: TaskNode] {
        var all: [String: TaskNode] = [:]
        for node in nodes {
            all[node.id] = node
            all.merge(flatten(node.children)) { a, _ in a }
        }
        return all
    }
}
#endif
