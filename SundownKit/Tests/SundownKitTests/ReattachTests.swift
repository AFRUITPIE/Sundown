import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownFixtures
import SundownTestSupport

@MainActor
@Suite(.serialized)
struct ReattachTests {
    private let threadID = "long-running-ssh-thread"

    @Test func reconnectSubscribesAfterLastSeenSequenceAndKeepsModelIdentity() async throws {
        let first = host(reads: [readResult(text: "before", sequence: 40)], subscriptions: [subscribeResult(lastSequence: 40)])
        let second = host(reads: [], subscriptions: [subscribeResult(lastSequence: 43)])
        let connection = makeConnection([first, second])

        await connection.connect()
        let thread = connection.thread(threadID)
        thread.setSummary(summary())
        await connection.open(thread)
        first.emit("item/agentMessage/delta", [
            "threadId": .string(threadID), "seq": 41, "itemId": "answer", "delta": " during",
        ])
        try await eventually { thread.lastSeq == 41 }

        let originalIdentity = ObjectIdentifier(thread)
        await connection.reconnect()

        #expect(ObjectIdentifier(connection.thread(threadID)) == originalIdentity)
        #expect(afterSeqs(second) == [41])

        second.emit("item/agentMessage/delta", [
            "threadId": .string(threadID), "seq": 42, "itemId": "answer", "delta": " after",
        ])
        second.emit("thread/status/changed", [
            "threadId": .string(threadID), "seq": 43, "status": "idle",
        ])
        try await eventually { thread.lastSeq == 43 }

        #expect(agentText(in: thread) == "before during after")
        #expect(thread.items.filter { $0.id == "answer" }.count == 1)
        #expect(thread.status == .idle)
        await connection.disconnect()
    }

    @Test func restartedFollowerReloadsSnapshotBeforeResubscribing() async throws {
        let first = host(reads: [readResult(text: "before", sequence: 40)], subscriptions: [subscribeResult(lastSequence: 40)])
        let restarted = host(reads: [readResult(text: "complete remote transcript", sequence: 100)],
                             subscriptions: [subscribeResult(lastSequence: 0), subscribeResult(lastSequence: 100)])
        let connection = makeConnection([first, restarted])

        await connection.connect()
        let thread = connection.thread(threadID)
        thread.setSummary(summary())
        await connection.open(thread)
        first.emit("item/agentMessage/delta", [
            "threadId": .string(threadID), "seq": 41, "itemId": "answer", "delta": " during",
        ])
        try await eventually { thread.lastSeq == 41 }

        await connection.reconnect()

        #expect(afterSeqs(restarted) == [41, 100])
        #expect(thread.lastSeq == 100)
        #expect(agentText(in: thread) == "complete remote transcript")
        #expect(thread.items.filter { $0.id == "answer" }.count == 1)
        await connection.disconnect()
    }

    @Test func sendingIntoAFollowedThreadResumesItInItsOwnSequence() async throws {
        let script = host(
            reads: [readResult(text: "watched", sequence: 500)],
            subscriptions: [subscribeResult(lastSequence: 500, status: .notLoaded)],
            resume: .init(thread: .init(threadId: threadID, status: .idle, cwd: "/work/project", lastSeq: 3),
                          items: [.agentMessage(.init(id: "answer", createdAt: 1, text: "resumed"))],
                          turns: [], historySeq: 3, hasMore: true)
        )
        let connection = makeConnection([script])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)

        await connection.send(thread, input: [.text(.init(text: "hi"))])

        #expect(script.calls(of: "thread/resume").map { $0["limit"]?.intValue } == [HostConnection.initialHistoryLimit])
        #expect(thread.lastSeq == 3)
        #expect(thread.hasMoreHistory)
        #expect(!thread.isFollowed)
        // The live thread's events start after 3, far below the follower's 500.
        script.emit("thread/status/changed", [
            "threadId": .string(threadID), "seq": 4, "status": "running",
        ])
        try await eventually { thread.status == .running }
        await connection.disconnect()
    }

    /// The daemon closed the thread's query (it exited, or was closed or rewound): the next send
    /// resumes it and takes up the new stream's numbering, rather than turning into a subscription
    /// to the process that ended and dropping every event of the new one.
    @Test func aThreadWhoseQueryEndedResumesOnTheNextSend() async throws {
        let newStream = 1_790_000_000_000_000
        let script = host(
            reads: [readResult(text: "before", sequence: 40)],
            subscriptions: [subscribeResult(lastSequence: 40, status: .idle)],
            resume: .init(thread: .init(threadId: threadID, status: .idle, cwd: "/work/project", lastSeq: newStream + 2),
                          items: [.agentMessage(.init(id: "answer", createdAt: 1, text: "before"))],
                          turns: [], historySeq: newStream + 2)
        )
        let connection = makeConnection([script])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        script.emit("thread/closed", ["threadId": .string(threadID), "seq": 41])
        try await eventually { thread.status == .closed }

        await connection.send(thread, input: [.text(.init(text: "again"))])

        #expect(script.count("thread/resume") > 0)
        #expect(thread.lastSeq == newStream + 2)
        script.emit("thread/status/changed", [
            "threadId": .string(threadID), "seq": .number(Double(newStream + 3)), "status": "running",
        ])
        try await eventually { thread.status == .running }
        await connection.disconnect()
    }

    /// A close from a stream already replaced (its seq behind the chat's) is ignored: the chat
    /// neither reads as closed nor resumes on the next send, which would reload it under a live
    /// turn (#35).
    @Test func aStaleStreamsCloseChangesNothing() async throws {
        let script = host(reads: [readResult(text: "before", sequence: 40)],
                          subscriptions: [subscribeResult(lastSequence: 40, status: .idle)])
        let connection = makeConnection([script])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        script.emit("thread/closed", ["threadId": .string(threadID), "seq": 12])
        // Something after it on the live stream that leaves the status alone, so the close has
        // surely been read.
        script.emit("thread/promptSuggestion", [
            "threadId": .string(threadID), "seq": 41, "suggestion": "Run the tests",
        ])
        try await eventually { thread.lastSeq == 41 }
        #expect(thread.status == .idle, "A stale stream's close changed the chat's status")

        await connection.send(thread, input: [.text(.init(text: "again"))])

        #expect(script.count("thread/resume") == 0, "A stale stream's close made the next send resume the chat")
        #expect(script.count("turn/start") > 0)
        await connection.disconnect()
    }

    @Test func settingsChosenForAnUnloadedThreadApplyWhenItResumes() async throws {
        let script = host(
            reads: [readResult(text: "watched", sequence: 7)],
            subscriptions: [subscribeResult(lastSequence: 7, status: .notLoaded)],
            resume: .init(thread: .init(threadId: threadID, status: .idle, cwd: "/work/project",
                                        model: "claude-sonnet-5", lastSeq: 1),
                          items: [], turns: [], historySeq: 1)
        )
        let connection = makeConnection([script])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)

        await connection.setModel(thread, "claude-sonnet-5")
        await connection.setEffort(thread, .low)

        #expect(thread.lastError == nil)
        #expect(thread.model == "claude-sonnet-5")
        #expect(thread.effort == .low)
        #expect(script.count("thread/setModel") == 0)

        await connection.send(thread, input: [.text(.init(text: "hi"))])

        #expect(script.calls(of: "thread/resume").first?["model"]?.stringValue == "claude-sonnet-5")
        #expect(script.calls(of: "thread/resume").first?["effort"]?.stringValue == "low")
        #expect(thread.pendingSettings == PendingSettings())
        await connection.disconnect()
    }

    // MARK: a replay gap on reconnecting

    /// Two connections to one chat: the first holds its last page and an older page the reader
    /// scrolled to; after a reconnect whose subscription reports a gap, the chat reloads, reading
    /// back as far as it held: every row the reader held survives the reload.
    @Test func aGapReconnectKeepsTheOlderRowsTheReaderHeld() async throws {
        let (before, after) = try await reconnectAfterOlderPage(gap: true)
        #expect(after.count == before.count, "a gap reload dropped \(before.count - after.count) rows the reader held")
        #expect(Set(before).isSubset(of: Set(after)))
    }

    /// Without a gap, the reconnect keeps everything the chat held (the control for the test above).
    @Test func aReconnectWithoutAGapKeepsEveryRow() async throws {
        let (before, after) = try await reconnectAfterOlderPage(gap: false)
        #expect(after == before)
    }

    /// Loads a 120-item chat as its last page of 50 and an older page of 70, then reconnects to the
    /// same daemon state with the subscription reporting `gap`. Returns the row ids before and after.
    private func reconnectAfterOlderPage(gap: Bool) async throws -> ([String], [String]) {
        func message(_ n: Int) -> Item {
            n % 10 == 0
                ? .userMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), content: [.text(.init(text: "Prompt \(n)"))]))
                : .agentMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), text: "Reply \(n)"))
        }
        let all = (0..<120).map(message)
        let tail = Array(all.suffix(50)), head = Array(all.prefix(70))
        let id = threadID
        func subscription(_ gap: Bool) -> ThreadSubscribeResult {
            ThreadSubscribeResult(thread: .init(threadId: id, status: .idle, cwd: "/repo", lastSeq: 200), replayed: 0, gap: gap)
        }

        let first = FakeHost()
        first.queue("thread/read", ThreadReadResult(items: tail, turns: [], historySeq: 200, hasMore: true))
        first.queue("thread/subscribe", subscription(false))
        first.queue("thread/read", ThreadReadResult(items: head, turns: [], hasMore: false))

        let second = FakeHost()
        if gap {
            second.queue("thread/subscribe", subscription(true))
            // The reload asks for at least as much as the chat held; the daemon answers with that
            // many from the end (here the whole chat).
            second.queue("thread/read", ThreadReadResult(items: all, turns: [], historySeq: 200, hasMore: false))
            second.queue("thread/subscribe", subscription(false))
        } else {
            second.queue("thread/subscribe", subscription(false))
        }

        let connection = FakeHost.connection(to: [first, second])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        await connection.loadOlderHistory(thread)
        let before = thread.rows(.summarized).map(\.id)
        #expect(thread.items.count == 120)

        await connection.reconnect()
        let after = thread.rows(.summarized).map(\.id)
        await connection.disconnect()
        return (before, after)
    }

    /// A daemon on claude-box with each read and subscription given once, in turn (a call past
    /// them is an error), and `resume` for every resume.
    private func host(reads: [ThreadReadResult], subscriptions: [ThreadSubscribeResult], resume: ThreadResumeResult? = nil) -> FakeHost {
        let host = FakeHost(hostname: "claude-box")
        for read in reads { host.once("thread/read", with: read) }
        for subscription in subscriptions { host.once("thread/subscribe", with: subscription) }
        if let resume { host.answer("thread/resume", with: resume) }
        host.answer("turn/start", with: TurnStartResult(turnId: "t", messageId: "m", queued: false))
        return host
    }

    /// A connection to each of `hosts` in turn.
    private func makeConnection(_ hosts: [FakeHost]) -> HostConnection {
        FakeHost.connection(to: hosts, host: HostConfig(name: "SSH fixture", kind: .ssh(destination: "claude-box")))
    }

    private func afterSeqs(_ host: FakeHost) -> [Int?] { host.calls(of: "thread/subscribe").map { $0["afterSeq"]?.intValue } }

    private func summary() -> ThreadSummary {
        .init(threadId: threadID, title: "Long-running remote work", cwd: "/work/project",
              updatedAt: 1, status: .running)
    }

    private func readResult(text: String, sequence: Int) -> ThreadReadResult {
        .init(items: [.agentMessage(.init(id: "answer", createdAt: 1, text: text))],
              turns: [], summary: summary(), historySeq: sequence, hasMore: false)
    }

    private func subscribeResult(lastSequence: Int, status: ThreadStatus = .running) -> ThreadSubscribeResult {
        .init(thread: .init(threadId: threadID, status: status, cwd: "/work/project", lastSeq: lastSequence),
              replayed: 0, gap: false)
    }

    private func agentText(in thread: ThreadModel) -> String? {
        thread.items.compactMap { item in
            if case .agentMessage(let message) = item { return message.text }
            return nil
        }.first
    }

}
