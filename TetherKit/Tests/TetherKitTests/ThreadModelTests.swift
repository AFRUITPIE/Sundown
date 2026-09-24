import Observation
import Testing
import TetherProtocol
@testable import TetherKit

@MainActor
@Suite
struct ThreadModelTests {
    private let threadID = "thread-under-test"

    private func userMessage(_ text: String, id: String = "u1", synthetic: Bool? = nil) -> Item {
        .userMessage(.init(id: id, createdAt: 0, content: [.text(.init(text: text))], synthetic: synthetic))
    }

    private func started(_ item: Item, seq: Int) -> ServerNotification {
        .itemStarted(.init(threadId: threadID, seq: seq, item: item))
    }

    @Test func theOpeningPromptNamesAnUnnamedThread() {
        let thread = ThreadModel(id: threadID)
        #expect(thread.title == "New Chat")

        thread.apply(started(userMessage("/compact"), seq: 1))
        thread.apply(started(userMessage("Rebuild the window layout", id: "u2"), seq: 2))

        #expect(thread.title == "/compact")
        #expect(thread.isUnnamed)
    }

    @Test func syntheticMessagesNeverNameAThread() {
        let thread = ThreadModel(id: threadID)

        thread.apply(started(userMessage("Caveat: this message was injected", synthetic: true), seq: 1))
        #expect(thread.title == "New Chat")

        thread.apply(started(userMessage("Rebuild the window layout", id: "u2"), seq: 2))
        #expect(thread.title == "Rebuild the window layout")
    }

    /// The point of storing the title: reading it must not subscribe a view to `items`.
    @Test func streamedDeltasLeaveTheTitleAlone() {
        let thread = ThreadModel(id: threadID)
        thread.apply(started(userMessage("Rebuild the window layout"), seq: 1))
        #expect(thread.title == "Rebuild the window layout")

        let observed = Invalidation()
        // The Tasks inspector's list, too: streamed text is not a task change.
        withObservationTracking { _ = thread.title; _ = thread.taskEntries } onChange: { observed.happened = true }

        thread.apply(started(.agentMessage(.init(id: "a1", createdAt: 0, text: "")), seq: 2))
        for (offset, delta) in ["On ", "it", "."].enumerated() {
            thread.apply(.itemAgentMessageDelta(.init(threadId: threadID, seq: 3 + offset, itemId: "a1", delta: delta)))
        }
        thread.apply(.itemToolCallProgress(.init(threadId: threadID, seq: 6, itemId: "a1", elapsedSeconds: 2)))

        #expect(!observed.happened)
        #expect(thread.title == "Rebuild the window layout")
    }

    @Test func aNamedSessionOutranksTheOpeningPrompt() {
        let thread = ThreadModel(id: threadID)
        thread.apply(started(userMessage("Rebuild the window layout"), seq: 1))

        thread.setSummary(.init(threadId: threadID, title: "Window layout rebuild", updatedAt: 1, status: .idle))
        #expect(thread.title == "Window layout rebuild")
        #expect(!thread.isUnnamed)

        thread.apply(.threadUpdated(.init(threadId: threadID, seq: 2, thread: .init(
            threadId: threadID, status: .idle, cwd: "/work/project", title: "Split view rebuild", lastSeq: 2))))
        #expect(thread.title == "Split view rebuild")

        // A rename lands as customTitle on the reloaded summary and wins over both.
        thread.setSummary(.init(threadId: threadID, title: "Window layout rebuild", customTitle: "Layout",
                                updatedAt: 3, status: .idle))
        #expect(thread.title == "Layout")
    }

    @Test func historyAndUnloadKeepTheTitleInStep() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [userMessage("Rebuild the window layout")], turns: [], seq: 10)
        #expect(thread.title == "Rebuild the window layout")

        thread.loadHistory(items: [userMessage("Audit the transcript rows", id: "u9")], turns: [], seq: 20, hasMore: true)
        #expect(thread.title == "Audit the transcript rows")

        thread.prependHistory(items: [userMessage("The first thing I ever asked", id: "u0")], hasMore: false)
        #expect(thread.title == "The first thing I ever asked")

        thread.unload()
        #expect(thread.title == "New Chat")
    }

    @Test func taskEntriesFollowTaskEventsWithoutAnyItemChange() {
        let thread = ThreadModel(id: threadID)
        #expect(thread.taskEntries.isEmpty)
        let itemsVersion = thread.itemsVersion

        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "task_started", taskId: "task-1",
                                      description: "Explore the inspector", status: "running", data: [:])))
        #expect(thread.taskEntries.map(\.id) == ["task:task-1"])
        #expect(thread.taskEntries.first?.isBackgrounded == false)

        thread.apply(.taskBackgroundChanged(.init(threadId: threadID, seq: 2, tasks: [["task_id": "task-1"]])))
        #expect(thread.taskEntries.first?.isBackgrounded == true)

        #expect(thread.itemsVersion == itemsVersion)
    }
}

/// Observation's `onChange` is `@Sendable`, so the flag it sets needs a reference to live in.
private final class Invalidation: @unchecked Sendable {
    var happened = false
}
