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
        #expect(all["workflow-call"]?.kind == .workflow)
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

    /// A workflow's agents are its children, by phase in the phases' order, what's still going
    /// first in each, with their states and times; the workflow is called by its name.
    @Test func aWorkflowsAgentsAreItsChildrenByPhase() throws {
        let thread = ThreadModel.sampleWorkflow(running: true)
        let workflow = try #require(TaskNode.tree(thread.taskEntries, call: thread.call).first { $0.id == "workflow-call" })
        #expect(workflow.title == "review-diff")
        #expect(workflow.state == .running)
        #expect(workflow.stoppableTaskID == "wf-1")
        let agents = workflow.children
        #expect(agents.map(\.phase) == ["Review", "Review", "Review", "Verify", "Verify"])
        #expect(agents.map(\.title) == ["TaskTree.swift", "TasksPane.swift", "ThreadModel.swift", "skeptic 1", "skeptic 2"])
        #expect(agents.map(\.state) == [.done, .done, .done, .running, .waiting])
        #expect(agents[0].seconds == 118)
        #expect(agents[3].started != nil && agents[3].seconds == nil)
        #expect(agents.allSatisfy { $0.kind == .agent && $0.stoppableTaskID == nil })
        #expect(agents[3].id == "workflow-call/agent/4")
        #expect(TaskNode.path(to: "workflow-call/agent/4", in: [workflow]) == ["workflow-call", "workflow-call/agent/4"])

        let sections = TaskNode.phaseSections(agents)
        #expect(sections.map(\.title) == ["Review", "Verify"])
        #expect(sections.map(\.nodes.count) == [3, 2])
        // One phase, or tasks that aren't a workflow's agents, have no sections.
        #expect(TaskNode.phaseSections(Array(agents.prefix(3))).count == 1)
        #expect(TaskNode.phaseSections(tree()).count == 1)
    }

    @Test func aFinishedWorkflowKeepsItsTime() throws {
        let thread = ThreadModel.sampleWorkflow(running: false)
        let workflow = try #require(TaskNode.tree(thread.taskEntries, call: thread.call).first { $0.id == "workflow-call" })
        #expect(workflow.state == .done)
        #expect(workflow.seconds == 238)
        #expect(workflow.stoppableTaskID == nil)
        #expect(workflow.children.allSatisfy { $0.state == .done })
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
