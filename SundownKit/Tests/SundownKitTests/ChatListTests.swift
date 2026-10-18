import Foundation
import Observation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownFixtures
import SundownTestSupport

/// The chat list is fetched on connecting and after an explicit action, and kept current between
/// by `thread/summaryChanged`; the sidebar regroups whenever it's set, so it's set only when it
/// changes.
@MainActor
@Suite(.serialized)
struct ChatListTests {
    private func summary(_ id: String, _ title: String, updated: Double) -> ThreadSummary {
        .init(threadId: id, title: title, cwd: "/repo", updatedAt: updated, status: .idle)
    }

    private func list(_ summaries: ThreadSummary...) -> ThreadListResult { .init(threads: summaries) }

    private func connected(_ host: FakeHost) async -> HostConnection {
        let connection = host.connection()
        await connection.connect()
        return connection
    }

    /// A summary told host-wide takes its chat's place by when it changed, whether this client
    /// follows the chat or not: a new title, the chat to the top, below a chat not written yet; a
    /// chat new to the list joins it, and its directory is the most recent. Nothing is asked again.
    @Test func aSummaryChangedTakesItsPlace() async throws {
        let host = FakeHost()
        host.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2),
                                                      summary("c", "C", updated: 1)))
        let connection = await connected(host)
        host.emit("thread/started", json(ThreadStartedNotification(
            threadId: "new", seq: 1, thread: .init(threadId: "new", status: .running, cwd: "/new", lastSeq: 1))))
        try await eventually { connection.chats.first?.id == "new" }
        let asked = host.calls(of: "thread/list").count

        host.emit("thread/summaryChanged", json(ThreadSummaryChangedNotification(summary: summary("c", "Claude's name for C", updated: 4))))
        try await eventually { connection.chats.map(\.id) == ["new", "c", "a", "b"] }
        #expect(connection.thread("c").title == "Claude's name for C")

        var other = summary("d", "D", updated: 2.5)
        other.cwd = "/elsewhere"
        host.emit("thread/summaryChanged", json(ThreadSummaryChangedNotification(summary: other)))
        try await eventually { connection.chats.map(\.id) == ["new", "c", "a", "d", "b"] }
        #expect(connection.directories == ["/new", "/repo", "/elsewhere"])
        #expect(host.calls(of: "thread/list").count == asked)
        await connection.disconnect()
    }

    /// A chat deleted here stays gone, though a summary of it was already on its way.
    @Test func aDeletedChatTakesNoSummary() async throws {
        let host = FakeHost()
        host.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2)))
        host.queue("thread/delete", ThreadDeleteResult())
        let connection = await connected(host)
        await connection.delete(connection.thread("a"))
        host.emit("thread/summaryChanged", json(ThreadSummaryChangedNotification(summary: summary("a", "A", updated: 4))))
        host.emit("thread/summaryChanged", json(ThreadSummaryChangedNotification(summary: summary("b", "B again", updated: 5))))
        try await eventually { connection.thread("b").title == "B again" }
        #expect(connection.chats.map(\.id) == ["b"])
        await connection.disconnect()
    }

    @Test func aListThatHasntChangedChangesNothing() async throws {
        let host = FakeHost()
        host.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2)))
        let connection = await connected(host)
        #expect(connection.chats.map(\.id) == ["a", "b"])

        let a = connection.thread("a")
        let summaries = observing { _ = a.summary; _ = a.status; _ = a.title }
        await expectUnchanged(reading: { _ = connection.chats }, during: { await connection.loadChats() })
        #expect(!summaries.happened)
        await connection.disconnect()
    }

    /// The host's list is the list: a chat deleted elsewhere, or past the limit, goes. A chat started
    /// here and not yet written to disk stays on top.
    @Test func aChatGoneFromTheHostsListGoes() async throws {
        let host = FakeHost()
        host.queue("thread/list", list(summary("a", "A", updated: 3), summary("b", "B", updated: 2),
                                                      summary("c", "C", updated: 1)))
        let connection = await connected(host)
        host.emit("thread/started", json(ThreadStartedNotification(
            threadId: "new", seq: 1, thread: .init(threadId: "new", status: .running, cwd: "/repo", lastSeq: 1))))
        try await eventually { connection.chats.first?.id == "new" }

        host.queue("thread/list", list(summary("a", "A", updated: 3), summary("c", "C", updated: 1)))
        await connection.loadChats()

        #expect(connection.chats.map(\.id) == ["new", "a", "c"])
        #expect(host.calls(of: "thread/list").last?["limit"]?.intValue == 200)
        await connection.disconnect()
    }

    /// Info and status that come again unchanged don't redraw what shows them.
    @Test func unchangedInfoAndStatusAreNotSetAgain() {
        let thread = ThreadModel(id: "t")
        let info = ThreadInfo(threadId: "t", status: .idle, cwd: "/repo", lastSeq: 1)
        thread.setInfo(info)
        thread.apply(.threadStatusChanged(.init(threadId: "t", seq: 2, status: .idle)))
        func read() { _ = thread.info; _ = thread.status; _ = thread.activity }
        expectUnchanged(reading: read) {
            thread.setInfo(info)
            thread.apply(.threadUpdated(.init(threadId: "t", seq: 3, thread: info)))
            thread.apply(.threadStatusChanged(.init(threadId: "t", seq: 4, status: .idle)))
        }
        let observed = observing(read)
        thread.apply(.threadStatusChanged(.init(threadId: "t", seq: 5, status: .running)))
        #expect(observed.happened)
    }
}

