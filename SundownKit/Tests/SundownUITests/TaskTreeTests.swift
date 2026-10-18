#if DEBUG
import Foundation
import Testing
@testable import SundownKit
import TetherProtocol
@testable import SundownUI

/// The Tasks tab's columns: each task under the one that started it, with what it is and how it stands.
@MainActor
@Suite
struct TaskTreeTests {
    private func tree() -> [TaskNode] {
        let thread = ThreadModel.sampleWithTaskKinds()
        return TaskNode.tree(thread.tasks, call: thread.call)
    }

    @Test func eachTaskIsUnderTheTaskThatStartedIt() {
        let top = tree()
        let agent = top.first { $0.id == "agent-1" }
        #expect(agent != nil)
        // The agent's own agent, and the command it ran in the background, as the daemon says.
        #expect(Set(agent?.children.map(\.id) ?? []) == ["agent-2", "bg-call"])
        #expect(!top.contains { $0.id == "agent-2" || $0.id == "bg-call" })
    }

    @Test func kindsAreNamedAsTheDaemonSaysThem() {
        let all = flatten(tree())
        #expect(all["workflow-call"]?.kindName == "Workflow")
        #expect(all["agent-1"]?.kindName == "Agent")
        #expect(all["bg-call"]?.kindName == "Command")
        #expect(all["task:monitor-1"]?.kindName == "Monitor")
        #expect(all["task:mcp-1"]?.kindName == "MCP Tool")
        // One this app doesn't know yet, by the CLI's own name for it.
        let other = TaskNode(task: .init(id: "x", kind: "somethingNew", taskType: "remote_shell", title: "x", status: .running))
        #expect(other.kindName == "Remote Shell")
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
        let workflow = try #require(TaskNode.tree(thread.tasks, call: thread.call).first { $0.id == "workflow-call" })
        #expect(workflow.title == "review-diff")
        #expect(workflow.state == .running)
        #expect(workflow.stoppableTaskID == "wf-1")
        let agents = workflow.children
        #expect(agents.map(\.phase) == ["Review", "Review", "Review", "Verify", "Verify"])
        #expect(agents.map(\.title) == ["TaskTree.swift", "TasksPane.swift", "ThreadModel.swift", "skeptic 1", "skeptic 2"])
        #expect(agents.map(\.state) == [.done, .done, .done, .running, .waiting])
        #expect(agents[0].seconds == 118)
        #expect(agents[3].started != nil && agents[3].seconds == nil)
        #expect(agents.allSatisfy { $0.kindName == "Agent" && $0.isWorkflowAgent && $0.stoppableTaskID == nil })
        #expect(agents[3].id == "workflow-call/agent/4")
        #expect(TaskNode.path(to: "workflow-call/agent/4", in: [workflow]) == ["workflow-call", "workflow-call/agent/4"])

        let sections = TaskNode.phaseSections(agents)
        #expect(sections.map(\.title) == ["Review", "Verify"])
        #expect(sections.map(\.nodes.count) == [3, 2])
        // One phase, or tasks that aren't a workflow's agents, have no sections.
        #expect(TaskNode.phaseSections(Array(agents.prefix(3))).count == 1)
        #expect(TaskNode.phaseSections(tree()).count == 1)
    }

    /// Agents in no phase come first, in a section with no header, never under an empty one.
    @Test func agentsInNoPhaseHaveNoHeader() throws {
        func agent(_ index: Int, _ title: String, phase: Int?, _ status: TaskStatus) -> TaskState {
            TaskState(id: "wf/agent/\(index)", parentId: "wf", kind: .workflowAgent, title: title, status: status,
                      workflowAgent: .init(index: index, phase: phase == 1 ? "Scan" : phase == 2 ? "Review" : nil, phaseIndex: phase))
        }
        let tasks = [
            TaskState(id: "wf", kind: .workflow, title: "wf", status: .running, workflow: .init(runId: "r", phases: [
                .init(index: 1, title: "Scan", status: .done), .init(index: 2, title: "Review", status: .running),
            ])),
            agent(1, "scan", phase: 1, .done), agent(2, "loose", phase: nil, .running), agent(3, "review", phase: 2, .running),
        ]
        let workflow = try #require(TaskNode.tree(tasks, call: { _ in nil }).first)
        #expect(workflow.children.map(\.title) == ["loose", "scan", "review"])
        #expect(workflow.children.allSatisfy { $0.runId == "r" })
        let sections = TaskNode.phaseSections(workflow.children)
        #expect(sections.map(\.title) == [nil, "Scan", "Review"])
    }

    @Test func aFinishedWorkflowKeepsItsTime() throws {
        let thread = ThreadModel.sampleWorkflow(running: false)
        let workflow = try #require(TaskNode.tree(thread.tasks, call: thread.call).first { $0.id == "workflow-call" })
        #expect(workflow.state == .done)
        #expect(workflow.seconds == 238)
        #expect(workflow.stoppableTaskID == nil)
        #expect(workflow.children.allSatisfy { $0.state == .done })
    }

    /// A workflow agent's own background command is under that agent, as the daemon says
    /// (`parentId`), never at the top.
    @Test func anAgentsOwnCommandIsUnderItsAgent() throws {
        let thread = ThreadModel.sampleWorkflow(running: true)
        let top = TaskNode.tree(thread.tasks, call: thread.call)
        #expect(top.map(\.id) == ["workflow-call"])
        let workflow = try #require(top.first)
        #expect(workflow.children.allSatisfy { $0.isWorkflowAgent })
        let skeptic = try #require(workflow.children.first { $0.title == "skeptic 1" })
        #expect(skeptic.children.map(\.id) == ["skeptic-1-bash"])
        let command = try #require(skeptic.children.first)
        #expect(command.kindName == "Command")
        #expect(command.title == "swift test --filter TaskTreeTests")
        #expect(command.state == .running)
        #expect(command.stoppableTaskID == "bg-skeptic-1")
        #expect(TaskNode.path(to: "skeptic-1-bash", in: top) == ["workflow-call", skeptic.id, "skeptic-1-bash"])
    }

    /// A task whose parent isn't listed is at the top rather than lost.
    @Test func aTaskWhoseParentIsntListedIsAtTheTop() {
        let tasks = [TaskState(id: "orphan", parentId: "gone", kind: .command, title: "orphan", status: .running)]
        #expect(TaskNode.tree(tasks, call: { _ in nil }).map(\.id) == ["orphan"])
    }

    /// A /loop's job and a /goal are tasks of their own: the job named for its prompt, saying how
    /// often it fires; the goal for its condition, saying how many checks it has had.
    @Test func schedulesAndGoalsAreTasks() throws {
        let running = flatten(TaskNode.tree(ThreadModel.sampleScheduledWork(finished: false).tasks, call: { _ in nil }))
        let job = try #require(running["schedule:cron-create"])
        #expect(job.kindName == "Schedule")
        #expect(job.title == "reply with the current time in one short line")
        #expect(job.state == .running)
        #expect(job.note == "Every minute")
        #expect(job.stoppableTaskID == nil)
        let goal = try #require(running["goal:goal-set"])
        #expect(goal.kindName == "Goal" && goal.title == "notes.md in this directory has no spelling mistakes")
        #expect(goal.state == .running)
        #expect(goal.note == "1 check")

        let finished = flatten(TaskNode.tree(ThreadModel.sampleScheduledWork(finished: true).tasks, call: { _ in nil }))
        #expect(finished["schedule:cron-create"]?.state == .stopped)
        #expect(finished["schedule:cron-create"]?.note == "Fired 2 times")
        #expect(finished["goal:goal-set"]?.state == .done)
        #expect(finished["goal:goal-set"]?.note == "2 checks")
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
