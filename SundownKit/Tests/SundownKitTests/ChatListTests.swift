import Foundation
import Observation
import Testing
import TetherProtocol
@testable import SundownKit

/// The chat list is fetched after every turn; the sidebar regroups whenever it's set, so it's set
/// only when it changes, and only the latest few chats are asked for.
@MainActor
@Suite(.serialized)
struct ChatListTests {
    private func summary(_ id: String, _ title: String, updated: Double) -> ThreadSummary {
        .init(threadId: id, title: title, cwd: "/repo", updatedAt: updated, status: .idle)
    }

    private func list(_ summaries: ThreadSummary...) -> ThreadListResult { .init(threads: summaries) }

    private func connected(_ daemon: FakeDaemon) async -> HostConnection {
        let connection = daemon.connection()
        await connection.connect()
        return connection
    }

    @Test func aListThatHasntChangedChangesNothing() async throws {
        let daemon = FakeDaemon()
        await daemon.script.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2)))
        let connection = await connected(daemon)
        #expect(connection.chats.map(\.id) == ["a", "b"])

        let chats = Changed(), summaries = Changed()
        withObservationTracking { _ = connection.chats } onChange: { chats.happened = true }
        let a = connection.thread("a")
        withObservationTracking { _ = a.summary; _ = a.status; _ = a.title } onChange: { summaries.happened = true }

        await connection.loadChats()

        #expect(!chats.happened)
        #expect(!summaries.happened)
        await connection.disconnect()
    }

    /// The host's list is the list: a chat deleted elsewhere, or past the limit, goes. A chat started
    /// here and not yet written to disk stays on top.
    @Test func aChatGoneFromTheHostsListGoes() async throws {
        let daemon = FakeDaemon()
        await daemon.script.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2),
                                                      summary("c", "C", updated: 1)))
        let connection = await connected(daemon)
        daemon.emit("thread/started", encoded(ThreadStartedNotification(
            threadId: "new", seq: 1, thread: .init(threadId: "new", status: .running, cwd: "/repo", lastSeq: 1))))
        try await eventually { connection.chats.first?.id == "new" }

        await daemon.script.queue("thread/list", list(summary("a", "A", updated: 3), summary("c", "C", updated: 1)))
        await connection.loadChats()

        #expect(connection.chats.map(\.id) == ["new", "a", "c"])
        #expect(await daemon.script.params(of: "thread/list").last?["limit"]?.intValue == 200)
        await connection.disconnect()
    }

    /// After a turn only the latest few are asked for: they move to the top with their new titles,
    /// and the rest keep their places below.
    @Test func afterATurnOnlyTheLatestChatsAreAskedFor() async throws {
        let daemon = FakeDaemon()
        await daemon.script.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2),
                                                      summary("c", "C", updated: 1)))
        let connection = await connected(daemon)

        await daemon.script.queue("thread/list", list(summary("c", "Claude's name for C", updated: 4), summary("a", "A", updated: 3)))
        await connection.refreshRecentChats()

        #expect(await daemon.script.params(of: "thread/list").last?["limit"]?.intValue == HostConnection.recentChatsLimit)
        #expect(connection.chats.map(\.id) == ["c", "a", "b"])
        #expect(connection.thread("c").title == "Claude's name for C")
        await connection.disconnect()
    }

    /// Info and status that come again unchanged don't redraw what shows them.
    @Test func unchangedInfoAndStatusAreNotSetAgain() {
        let thread = ThreadModel(id: "t")
        let info = ThreadInfo(threadId: "t", status: .idle, cwd: "/repo", lastSeq: 1)
        thread.setInfo(info)
        thread.apply(.threadStatusChanged(.init(threadId: "t", seq: 2, status: .idle)))
        let observed = Changed()
        withObservationTracking { _ = thread.info; _ = thread.status; _ = thread.activity } onChange: { observed.happened = true }

        thread.setInfo(info)
        thread.apply(.threadUpdated(.init(threadId: "t", seq: 3, thread: info)))
        thread.apply(.threadStatusChanged(.init(threadId: "t", seq: 4, status: .idle)))

        #expect(!observed.happened)
        thread.apply(.threadStatusChanged(.init(threadId: "t", seq: 5, status: .running)))
        #expect(observed.happened)
    }
}

