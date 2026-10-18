import Foundation
@testable import SundownFixtures
import Testing
import TetherProtocol
@testable import SundownKit
import SundownTestSupport

/// A chat's tasks as the daemon states them: whole, replaced by id, in the order first seen, and
/// assigned only when one changes, so the Tasks tab and the rows that read them redraw only then.
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

    /// A finished workflow agent's transcript goes when its workflow's call does.
    @Test func trimmingLetsGoOfAgentTranscriptsWithTheirCall() {
        let thread = ThreadModel.sampleWorkflow(running: false)
        #expect(thread.workflowAgentTranscript(runId: WorkflowSample.runID, agentId: "a1f09c3e2b7d") != nil)
        thread.trim(toLast: thread.items.count)
        #expect(thread.workflowAgentTranscript(runId: WorkflowSample.runID, agentId: "a1f09c3e2b7d") != nil)
        thread.trim(toLast: 1)
        #expect(thread.workflowAgentTranscript(runId: WorkflowSample.runID, agentId: "a1f09c3e2b7d") == nil)
        // The tasks are the chat's, whatever its items.
        #expect(thread.tasks.count == WorkflowSample.tasks(now: 0, running: false).count + 1)
    }
}
