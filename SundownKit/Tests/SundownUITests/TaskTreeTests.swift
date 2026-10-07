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

    /// Agents in no phase come first, in a section with no header, never under an empty one.
    @Test func agentsInNoPhaseHaveNoHeader() throws {
        let snapshot: JSONValue = [
            "runId": "r", "status": "running",
            "phases": [["index": 1, "title": "Scan"], ["index": 2, "title": "Review"]],
            "agents": [
                ["index": 1, "label": "scan", "phaseIndex": 1, "state": "done"],
                ["index": 2, "label": "loose", "state": "progress"],
                ["index": 3, "label": "review", "phaseIndex": 2, "state": "progress"],
            ],
        ]
        let run = try #require(WorkflowRun(toolUseId: "wf", snapshot: snapshot))
        let entry = InspectorTaskEntry(id: "wf", call: nil, task: nil, isBackgrounded: false, workflow: run)
        let workflow = try #require(TaskNode.tree([entry], call: { _ in nil }).first)
        #expect(workflow.children.map(\.title) == ["loose", "scan", "review"])
        let sections = TaskNode.phaseSections(workflow.children)
        #expect(sections.map(\.title) == [nil, "Scan", "Review"])
    }

    @Test func aFinishedWorkflowKeepsItsTime() throws {
        let thread = ThreadModel.sampleWorkflow(running: false)
        let workflow = try #require(TaskNode.tree(thread.taskEntries, call: thread.call).first { $0.id == "workflow-call" })
        #expect(workflow.state == .done)
        #expect(workflow.seconds == 238)
        #expect(workflow.stoppableTaskID == nil)
        #expect(workflow.children.allSatisfy { $0.state == .done })
    }

    /// A workflow agent's own background command (slow-check's agents each ran `sleep 45`) is
    /// under that agent, never at the top: the daemon says whose it is on every event.
    @Test func anAgentsOwnCommandIsUnderItsAgent() throws {
        let thread = ThreadModel.sampleWorkflow(running: true)
        let top = TaskNode.tree(thread.taskEntries, call: thread.call)
        #expect(top.map(\.id) == ["workflow-call"])
        let workflow = try #require(top.first)
        #expect(workflow.children.allSatisfy { $0.kind == .agent })
        let skeptic = try #require(workflow.children.first { $0.title == "skeptic 1" })
        #expect(skeptic.children.map(\.id) == ["task:bg-skeptic-1"])
        let command = try #require(skeptic.children.first)
        #expect(command.kind == .command)
        #expect(command.title == "swift test --filter TaskTreeTests")
        #expect(command.state == .running)
        #expect(TaskNode.path(to: "task:bg-skeptic-1", in: top) == ["workflow-call", skeptic.id, "task:bg-skeptic-1"])
    }

    /// Until the daemon knows which agent ran it, an agent's command is under its workflow; with
    /// no workflow to go under (an older daemon says only `owned_by_subagent`, on the start) it
    /// isn't listed, though its later events don't say so again.
    @Test func anAgentsCommandWithNoAgentIsUnderItsWorkflowOrNowhere() throws {
        let thread = ThreadModel.sampleWorkflow(running: true)
        thread.apply(.taskEvent(.init(threadId: thread.id, seq: 200, event: "started", taskId: "bg-unplaced", toolUseId: "elsewhere-1",
                                      description: "sleep 45", status: "running", ownedBySubagent: true,
                                      workflowToolUseId: WorkflowSample.callID,
                                      data: ["task_type": "local_bash", "owned_by_subagent": true])))
        thread.apply(.taskEvent(.init(threadId: thread.id, seq: 201, event: "started", taskId: "bg-old-daemon", toolUseId: "elsewhere-2",
                                      description: "sleep 45", status: "running",
                                      data: ["task_type": "local_bash", "owned_by_subagent": true, "is_backgrounded": true])))
        thread.apply(.taskEvent(.init(threadId: thread.id, seq: 202, event: "notification", taskId: "bg-old-daemon",
                                      toolUseId: "elsewhere-2", status: "stopped", summary: "sleep 45", data: ["status": "stopped"])))
        let top = TaskNode.tree(thread.taskEntries, call: thread.call)
        #expect(top.map(\.id) == ["workflow-call"])
        let workflow = try #require(top.first)
        #expect(workflow.children.first?.id == "task:bg-unplaced")
        #expect(workflow.children.dropFirst().allSatisfy { $0.kind == .agent })
        #expect(flatten(top)["task:bg-old-daemon"] == nil)
        #expect(thread.taskEntries.contains { $0.id == "task:bg-old-daemon" && $0.task?.status == "stopped" })
    }

    /// A /loop's job and a /goal are tasks of their own: the job named for its prompt, saying how
    /// often it fires; the goal for its condition, saying how many checks it has had.
    @Test func schedulesAndGoalsAreTasks() throws {
        let running = flatten(TaskNode.tree(ThreadModel.sampleScheduledWork(finished: false).taskEntries, call: { _ in nil }))
        let job = try #require(running["schedule:cron-create"])
        #expect(job.kind == .schedule && job.kind.name == "Schedule")
        #expect(job.title == "reply with the current time in one short line")
        #expect(job.state == .running)
        #expect(job.note == "Every minute")
        #expect(job.stoppableTaskID == nil)
        let goal = try #require(running["goal:goal-set"])
        #expect(goal.kind == .goal && goal.title == "notes.md in this directory has no spelling mistakes")
        #expect(goal.state == .running)
        #expect(goal.note == "1 check")

        let finished = flatten(TaskNode.tree(ThreadModel.sampleScheduledWork(finished: true).taskEntries, call: { _ in nil }))
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
