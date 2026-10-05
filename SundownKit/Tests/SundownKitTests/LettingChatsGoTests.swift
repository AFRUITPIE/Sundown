import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// A chat no window shows holds only its last page, and nothing worked out from it, without losing
/// its place in the stream.
@MainActor
@Suite(.serialized)
struct LettingChatsGoTests {
    private let threadID = "live-chat"

    private func message(_ n: Int) -> Item {
        n % 10 == 0
            ? .userMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), content: [.text(.init(text: "Prompt \(n)"))]))
            : .agentMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), text: "Reply \(n)"))
    }

    private func edit(_ id: String, _ n: Int, parent: String? = nil, status: ToolStatus = .completed) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: Double(1_000 + n), name: "Edit", kind: .fileEdit,
                        input: ["file_path": "/repo/a.swift", "old_string": "a\nb\nc", "new_string": "a\nB\nc\nd"], status: status))
    }

    private func subagent(_ id: String, _ n: Int) -> Item {
        .toolCall(.init(id: id, createdAt: Double(1_000 + n), name: "Task", kind: .subagent, input: [:], status: .completed))
    }

    /// Sixty items: prompts every ten, an edit, and a subagent with an item of its own.
    private var transcript: [Item] {
        var items = (0..<60).map(message)
        items[3] = edit("edit-early", 3)
        items[55] = subagent("agent", 55)
        items[56] = edit("agent-edit", 56, parent: "agent")
        items[57] = edit("edit-late", 57)
        return items
    }

    // MARK: the model

    @Test func unloadingLetsGoOfEverythingWorkedOut() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: transcript, turns: [], seq: 60)
        _ = thread.rows(.workedFor)
        _ = thread.rows
        _ = thread.topLevelItems
        _ = thread.children(of: "agent")
        #expect(thread.itemsHeld > 60)

        thread.unload()

        #expect(thread.itemsHeld == 0)
        #expect(thread.foldingsHeld.isEmpty)
        #expect(thread.rows(.workedFor).isEmpty)
    }

    @Test func trimmingKeepsTheLastPageAndItsPlaceInTheStream() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: transcript, turns: [.init(id: "t1", status: .completed, startedAt: 0)], seq: 100)
        _ = thread.rows(.summarized)

        thread.trim(toLast: 50)

        #expect(thread.items.map(\.id) == transcript.suffix(50).map(\.id))
        #expect(thread.lastSeq == 100)
        #expect(thread.historyLoaded && thread.hasMoreHistory)
        #expect(thread.turns.map(\.id) == ["t1"])
        #expect(thread.foldingsHeld.isEmpty)
        #expect(thread.fileChanges["edit-early"] == nil)
        #expect(thread.children(of: "agent").map(\.id) == ["agent-edit"])

        // The stream goes on from where it was: a replay of what's held is refused, the next event
        // applies.
        #expect(!thread.apply(.itemStarted(.init(threadId: threadID, seq: 100, item: message(90)))))
        #expect(thread.apply(.itemStarted(.init(threadId: threadID, seq: 101, item: message(61)))))
        #expect(thread.items.last?.id == "m61")
        #expect(thread.itemIndex(of: "m61") == 50)
    }

    @Test func trimmingAShortChatOnlyLetsGoOfTheRows() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: Array(transcript.prefix(20)), turns: [], seq: 20)
        _ = thread.rows(.summarized)
        thread.trim(toLast: 50)
        #expect(thread.items.count == 20)
        #expect(!thread.hasMoreHistory)
        #expect(thread.foldingsHeld.isEmpty)
    }

    /// Until Claude names it, a chat is called by its opening prompt, which trimming lets go of.
    @Test func trimmingKeepsAnUnnamedChatsTitle() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: transcript, turns: [], seq: 60)
        #expect(thread.title == "Prompt 0")
        thread.trim(toLast: 50)
        #expect(thread.title == "Prompt 0")
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 61, item: message(70))))
        #expect(thread.title == "Prompt 0")
    }

    /// As with a page loaded afresh, a finished task whose call was let go isn't listed; a running
    /// one still is, so it can be stopped.
    @Test func trimmingLetsGoOfFinishedTasksWhoseCallWent() {
        let thread = ThreadModel(id: threadID)
        var items = transcript
        items[2] = subagent("early-agent", 2)
        thread.loadHistory(items: items, turns: [], seq: 60)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 61, event: "started", taskId: "done", toolUseId: "early-agent",
                                      status: "completed", data: [:])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 62, event: "started", taskId: "going", toolUseId: "m4",
                                      status: "running", data: [:])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 63, event: "started", taskId: "late", toolUseId: "agent",
                                      status: "completed", data: [:])))

        thread.trim(toLast: 50)

        #expect(Set(thread.tasks.keys) == ["going", "late"])
        #expect(thread.taskEntries.map(\.id) == ["agent", "task:going"])
        #expect(thread.taskEvent(forToolUseId: "agent")?.taskId == "late")
    }

    /// A background command's call on a page not held, finishing now: the page brings it when it
    /// loads. Appended, it read as the chat's latest.
    @Test func anItemFromAPageNotHeldIsLeftToThatPage() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: Array(transcript.suffix(50)), turns: [], seq: 60, hasMore: true)
        let old = Item.toolCall(.init(id: "old-bash", createdAt: 1_001, name: "Bash", kind: .bash, input: [:], status: .completed))
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 61, item: old)))
        #expect(thread.itemIndex(of: "old-bash") == nil)
        #expect(thread.items.count == 50)
    }

    // MARK: the connection

    private func connect(_ daemon: FakeDaemon, status: ThreadStatus = .idle, items: [Item]? = nil,
                         historySeq: Int? = 100) async -> (HostConnection, ThreadModel) {
        await daemon.script.queue("thread/read", ThreadReadResult(items: items ?? transcript, turns: [], historySeq: historySeq, hasMore: false))
        await daemon.script.queue("thread/subscribe", ThreadSubscribeResult(
            thread: .init(threadId: threadID, status: status, cwd: "/repo", lastSeq: historySeq ?? 0), replayed: 0, gap: false))
        let connection = daemon.connection()
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        return (connection, thread)
    }

    @Test func leavingAnIdleLiveChatKeepsItsLastPageAndItsSubscription() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon)
        #expect(connection.isLoaded(thread))
        #expect(thread.items.count == 60)

        connection.leave(thread)

        #expect(thread.items.map(\.id) == transcript.suffix(50).map(\.id))
        #expect(thread.hasMoreHistory)
        #expect(connection.isLoaded(thread))
        #expect(await !daemon.script.calls.contains { $0.method == "thread/unsubscribe" })

        // Live events still arrive, after the last one seen.
        daemon.emit("item/started", encoded(ItemStartedNotification(threadId: threadID, seq: 101, item: message(61))))
        try await eventually { thread.items.last?.id == "m61" }

        // Shown again and scrolled up, the page let go comes back, before the first item held.
        await connection.open(thread)
        await daemon.script.queue("thread/read", ThreadReadResult(items: Array(transcript.prefix(10)), turns: [], hasMore: false))
        await connection.loadOlderHistory(thread)
        let older = await daemon.script.params(of: "thread/read").last
        #expect(older?["before"]?.stringValue == "m10")
        #expect(older?["limit"]?.intValue == HostConnection.olderHistoryPageSize)
        #expect(thread.items.map(\.id) == transcript.map(\.id) + ["m61"])
        #expect(!thread.hasMoreHistory)
        await connection.disconnect()
    }

    /// A page that arrives after the chat was trimmed under it would leave a gap: it's dropped,
    /// and asked for again from what's held now.
    @Test func aPageForItemsLetGoMeanwhileIsDropped() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon)
        connection.leave(thread)
        await connection.open(thread)
        #expect(thread.items.first?.id == "m10")

        await daemon.script.hold("thread/read")
        await daemon.script.queue("thread/read", ThreadReadResult(items: Array(transcript.prefix(10)), turns: [], hasMore: false))
        let loading = Task { await connection.loadOlderHistory(thread) }
        try await eventually { await daemon.script.params(of: "thread/read").count == 2 }
        for (n, seq) in zip(61...65, 101...) {
            daemon.emit("item/started", encoded(ItemStartedNotification(threadId: threadID, seq: seq, item: message(n))))
        }
        try await eventually { thread.items.last?.id == "m65" }
        connection.leave(thread)
        #expect(thread.items.first?.id == "m15")
        await daemon.script.release("thread/read")
        await loading.value

        #expect(thread.items.first?.id == "m15")
        #expect(thread.items.count == 50)
        #expect(thread.hasMoreHistory)
        #expect(!thread.loadingOlder)
        await connection.disconnect()
    }

    @Test func aChatLeftWhileRunningKeepsOnlyItsLastPageAfterItsTurn() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon, status: .running)
        connection.leave(thread)
        #expect(thread.items.count == 60)

        daemon.emit("thread/status/changed", ["threadId": .string(threadID), "seq": 101, "status": "idle"])
        try await eventually { thread.status == .idle }
        await connection.afterTurn()

        #expect(thread.items.count == 50)
        #expect(thread.lastSeq == 101)
        #expect(connection.isLoaded(thread))
        // And the chat list is refreshed with the latest few.
        #expect(await daemon.script.params(of: "thread/list").last?["limit"]?.intValue == HostConnection.recentChatsLimit)
        await connection.disconnect()
    }

    @Test func aChatOnScreenKeepsEverythingAfterATurn() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon)
        _ = thread.rows(.summarized)
        await connection.afterTurn()
        #expect(thread.items.count == 60)
        #expect(thread.foldingsHeld == [.summarized])
        await connection.disconnect()
    }

    /// A chat read from disk alone has no stream to keep a place in: it's let go as a followed one is.
    @Test func leavingAChatWithNoStreamLetsItGo() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon, historySeq: nil)
        #expect(thread.historyLoaded)
        connection.leave(thread)
        #expect(!thread.historyLoaded)
        #expect(thread.itemsHeld == 0)
        await connection.disconnect()
    }

    /// Nothing is subscribed while the host is down: a live chat isn't mistaken for one with no
    /// stream, and is still there to resubscribe when it comes back.
    @Test func leavingWhileDisconnectedLetsNothingGo() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon)
        await connection.disconnect()
        connection.leave(thread)
        #expect(thread.historyLoaded)
        #expect(thread.items.count == 60)
    }

    // MARK: edits counted off the main actor

    /// A page's edits are counted before it goes in, so drawing its rows only looks them up.
    @Test func aPagesEditsAreCountedBeforeItsFirstDraw() async throws {
        let daemon = FakeDaemon()
        let (connection, thread) = await connect(daemon)
        #expect(Set(thread.fileChanges.keys) == ["edit-early", "agent-edit", "edit-late"])
        #expect(thread.fileChanges["edit-late"] == FileChange.changes(of: {
            guard case .toolCall(let c) = edit("edit-late", 57) else { fatalError() }
            return c
        }()))
        _ = thread.rows(.summarized)
        #expect(thread.rows(.summarized).contains { $0.id == "edits-m50" })
        #expect(thread.changesCountedOnMainActor == 0)

        await daemon.script.queue("thread/read", ThreadReadResult(items: [edit("edit-older", -5)], turns: [], hasMore: false))
        connection.leave(thread)
        await connection.open(thread)
        await connection.loadOlderHistory(thread)
        #expect(thread.fileChanges["edit-older"] != nil)
        await connection.disconnect()
    }

    /// An edit finishing live is counted off the main actor too, by the time its turn ends.
    @Test func aFinishedEditIsCountedOffTheMainActor() async throws {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [message(0)], turns: [], seq: 1)
        thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 2, status: .running)))
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: edit("live-edit", 1, status: .running))))
        #expect(thread.fileChanges["live-edit"] == nil)
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 4, item: edit("live-edit", 1))))
        try await eventually { thread.fileChanges["live-edit"] != nil }
        thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 5, status: .idle)))
        #expect(thread.rows(.summarized).last?.id == "edits-m0")
        #expect(thread.changesCountedOnMainActor == 0)
    }
}
