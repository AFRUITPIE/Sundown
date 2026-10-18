import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownTestSupport

/// A chat's tasks as the daemon states them: whole, replaced by id, in the order first seen, the
/// chat's whatever page of items is held, and assigned only when one changes, so the Tasks tab and
/// the rows that read them redraw only then.
@MainActor
@Suite
struct TaskStateTests {
    private let threadID = "tasks"

    private func task(_ id: String, _ status: TaskStatus = .running, call: String? = nil, kind: TaskKind = .agent,
                      parent: String? = nil) -> TaskState {
        TaskState(id: id, parentId: parent, toolUseId: call, kind: kind, title: id, status: status)
    }

    private func updated(_ task: TaskState, _ seq: Int) -> ServerNotification {
        .taskUpdated(.init(threadId: threadID, seq: seq, task: task))
    }

    private func message(_ n: Int) -> Item { .agentMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), text: "Reply \(n)")) }

    private func call(_ id: String, _ name: String, kind: ToolKind, at n: Int, parent: String? = nil) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: Double(1_000 + n), name: name, kind: kind, input: [:],
                        status: .completed))
    }

    /// A read's tasks, then each update in place or, new, after them.
    @Test func updatesReplaceByIDInTheOrderFirstSeen() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [], turns: [], seq: 1, tasks: [task("a"), task("b")])
        thread.apply(updated(task("c"), 2))
        thread.apply(updated(task("a", .done), 3))
        #expect(thread.tasks.map(\.id) == ["a", "b", "c"])
        #expect(thread.tasks[0].status == .done)
        // A subscription's tasks are as they stand now, whole.
        thread.setTasks([task("b", .stopped), task("a", .done)])
        #expect(thread.tasks.map(\.id) == ["b", "a"])
        // An older page has no say: what the chat holds is newer.
        thread.prependHistory(items: [.agentMessage(.init(id: "m0", createdAt: 0, text: ""))], hasMore: false)
        #expect(thread.tasks.map(\.id) == ["b", "a"])
    }

    /// A task's update changes the tasks, not the transcript.
    @Test func tasksFollowTheirUpdatesWithoutAnyItemChange() {
        let thread = ThreadModel(id: threadID)
        #expect(thread.tasks.isEmpty)
        let itemsVersion = thread.itemsVersion

        thread.apply(.taskUpdated(.init(threadId: threadID, seq: 1, task: .init(
            id: "task:task-1", taskId: "task-1", kind: .agent, title: "Explore the inspector", status: .running))))
        #expect(thread.tasks.map(\.id) == ["task:task-1"])
        thread.apply(.taskUpdated(.init(threadId: threadID, seq: 2, task: .init(
            id: "task:task-1", taskId: "task-1", kind: .agent, title: "Explore the inspector", status: .running, backgrounded: true))))
        #expect(thread.tasks.first?.isInBackground == true)

        #expect(thread.itemsVersion == itemsVersion)
    }

    /// An agent's own steps are its call's children, not rows of the transcript; its task is the
    /// one its call started.
    @Test func anAgentsStepsAreItsCallsAndItsTaskIsTheCalls() {
        let thread = ThreadModel(id: threadID)
        let agent = "agent"
        thread.loadHistory(items: [
            .userMessage(.init(id: "p", createdAt: 1_000, content: [.text(.init(text: "Look around"))])),
            call(agent, "Task", kind: .subagent, at: 1),
            call("agent-grep", "Grep", kind: .grep, at: 2, parent: agent),
            .agentMessage(.init(id: "agent-note", parentToolUseId: agent, createdAt: 1_003, text: "Found 12 views.")),
        ], turns: [], seq: 1, tasks: [TaskState(id: agent, toolUseId: agent, taskId: "task-explore", kind: .agent,
                                                taskType: "local_agent", title: "Find every view", status: .running)])

        let task = thread.tasks.first { $0.id == agent }
        #expect(task?.kind == .agent)
        #expect(thread.callTasks[agent] == task)
        #expect(thread.children(of: agent).map(\.id) == ["agent-grep", "agent-note"])
        let rows = foldTranscriptRows(thread.topLevelItems)
        #expect(rows.contains { if case .item(.toolCall(let call)) = $0 { call.id == agent } else { false } })
        #expect(!rows.contains { row in thread.children(of: agent).contains { $0.id == row.id } })
    }

    /// The rows read the tasks calls started, by call: a workflow's agents, schedules and goals
    /// aren't among them, so their updates leave the rows alone.
    @Test func theRowsReadOnlyTheCallsTasks() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [], turns: [], seq: 1, tasks: [task("wf", call: "wf", kind: .workflow)])
        #expect(thread.callTasks.keys.sorted() == ["wf"])
        expectUnchanged(reading: { _ = thread.callTasks }) {
            thread.apply(updated(task("wf/agent/1", kind: .workflowAgent, parent: "wf"), 2))
            thread.apply(updated(task("schedule:c", kind: .schedule), 3))
        }
        #expect(thread.tasks.count == 3)
        let rows = observing { _ = thread.callTasks }
        thread.apply(updated(task("wf", .done, call: "wf", kind: .workflow), 4))
        #expect(rows.happened)
        #expect(thread.callTasks["wf"]?.status == .done)
    }

    /// What changes nothing leaves the list alone, and the pane with it.
    @Test func anUnchangedTaskIsNotAssignedAgain() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [], turns: [], seq: 1, tasks: [task("a", call: "a")])
        func read() { _ = thread.tasks; _ = thread.callTasks }
        expectUnchanged(reading: read) {
            thread.apply(updated(task("a", call: "a"), 2))
            thread.setTasks([task("a", call: "a")])
            thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: .agentMessage(.init(id: "m", createdAt: 1, text: "")))))
        }
        let observed = observing(read)
        thread.apply(updated(task("a", .done, call: "a"), 4))
        #expect(observed.happened)
    }

    /// The tasks are the chat's, as the daemon says them, whatever page of items is held: one whose
    /// call was let go is still listed, and can still be stopped.
    @Test func trimmingKeepsTheChatsTasks() {
        let thread = ThreadModel(id: threadID)
        var items = (0..<60).map(message)
        items[2] = call("early-agent", "Task", kind: .subagent, at: 2)
        items[55] = call("agent", "Task", kind: .subagent, at: 55)
        let tasks = [TaskState(id: "early-agent", toolUseId: "early-agent", kind: .agent, title: "early", status: .done),
                     TaskState(id: "agent", toolUseId: "agent", kind: .agent, title: "late", status: .running)]
        thread.loadHistory(items: items, turns: [], seq: 60, tasks: tasks)

        thread.trim(toLast: 50)

        #expect(thread.tasks == tasks)
        #expect(thread.callTasks.keys.sorted() == ["agent", "early-agent"])
    }

    /// A finished workflow agent's transcript goes when its workflow's call does.
    @Test func trimmingLetsGoOfAgentTranscriptsWithTheirCall() {
        let thread = ThreadModel(id: threadID)
        let workflow = TaskState(id: "wf", toolUseId: "wf", taskId: "wf-1", kind: .workflow, title: "review-diff", status: .done,
                                 workflow: .init(runId: "run-1", name: "review-diff", phases: []))
        let agent = TaskState(id: "wf/agent/1", parentId: "wf", kind: .workflowAgent, title: "reviewer", status: .done)
        thread.loadHistory(items: [message(0), call("wf", "Workflow", kind: .other, at: 1), message(2)], turns: [], seq: 1,
                           tasks: [workflow, agent])
        thread.rememberWorkflowAgentTranscript([message(10)], runId: "run-1", agentId: "a1")
        #expect(thread.workflowAgentTranscript(runId: "run-1", agentId: "a1") != nil)

        thread.trim(toLast: thread.items.count)
        #expect(thread.workflowAgentTranscript(runId: "run-1", agentId: "a1") != nil)
        thread.trim(toLast: 1)
        #expect(thread.workflowAgentTranscript(runId: "run-1", agentId: "a1") == nil)
        // The tasks are the chat's, whatever its items.
        #expect(thread.tasks == [workflow, agent])
    }
}
