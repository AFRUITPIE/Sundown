import Foundation
import Observation
import Testing
import TetherProtocol
@testable import TetherKit

/// The Tasks inspector's list is kept as subagent calls and task events arrive, not rebuilt from
/// every item, and set only when it changes.
@MainActor
@Suite
struct TaskEntriesTests {
    private let threadID = "tasks"

    private func subagent(_ id: String, parent: String? = nil, status: ToolStatus = .running) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: 1, name: "Task", kind: .subagent, input: [:], status: status))
    }

    private func message(_ id: String) -> Item { .agentMessage(.init(id: id, createdAt: 1, text: id)) }

    private func task(_ id: String, _ seq: Int, toolUseId: String?, status: String = "running") -> ServerNotification {
        .taskEvent(.init(threadId: threadID, seq: seq, event: "started", taskId: id, toolUseId: toolUseId, status: status, data: [:]))
    }

    /// Every subagent call in transcript order, a subagent's own included and an older page's
    /// first, then the tasks no call matches.
    @Test func entriesFollowTheTranscriptsOrder() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [message("m1"), subagent("s1")], turns: [], seq: 1, hasMore: true)
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 2, item: subagent("s2", parent: "s1"))))
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: subagent("s3"))))
        thread.apply(task("w1", 4, toolUseId: nil))
        thread.apply(task("k3", 5, toolUseId: "s3"))
        #expect(thread.taskEntries.map(\.id) == ["s1", "s2", "s3", "task:w1"])
        #expect(thread.taskEntries[2].task?.taskId == "k3")

        thread.prependHistory(items: [subagent("s0", status: .completed)], hasMore: false)
        #expect(thread.taskEntries.map(\.id) == ["s0", "s1", "s2", "s3", "task:w1"])
    }

    /// A call's task is the one with its latest event.
    @Test func aCallsTaskIsItsNewest() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [subagent("s1")], turns: [], seq: 1)
        thread.apply(task("first", 2, toolUseId: "s1", status: "failed"))
        thread.apply(task("second", 3, toolUseId: "s1"))
        #expect(thread.taskEvent(forToolUseId: "s1")?.taskId == "second")
        #expect(thread.taskEntries.map(\.id) == ["s1", "task:first"])
        // An update to the older one makes it the newest.
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 4, event: "updated", taskId: "first", status: "completed", data: [:])))
        #expect(thread.taskEvent(forToolUseId: "s1")?.taskId == "first")
        #expect(thread.taskEntries.map(\.id) == ["s1", "task:second"])
    }

    /// What changes nothing the list shows leaves it alone, and the pane with it.
    @Test func anEventThatChangesNothingShownLeavesTheListAlone() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [message("m1"), subagent("s1")], turns: [], seq: 1)
        thread.apply(task("k1", 2, toolUseId: "s1"))
        thread.apply(.taskBackgroundChanged(.init(threadId: threadID, seq: 3, tasks: [["task_id": "k1"]])))
        let observed = Changed()
        withObservationTracking { _ = thread.taskEntries; _ = thread.backgroundTaskIDs } onChange: { observed.happened = true }

        thread.apply(.taskBackgroundChanged(.init(threadId: threadID, seq: 4, tasks: [["task_id": "k1"]])))
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 5, item: message("m2"))))
        thread.prependHistory(items: [message("m0")], hasMore: false)
        thread.apply(.itemUpdated(.init(threadId: threadID, seq: 6, item: subagent("s1"))))

        #expect(!observed.happened)
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 7, item: subagent("s1", status: .completed))))
        #expect(observed.happened)
    }
}

