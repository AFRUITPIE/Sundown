import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// A chat started here shows at once, saying Starting Session, rather than when the host answers;
/// the host takes the client's ids, so its echo of the first prompt lands on the row already shown.
@MainActor
@Suite(.serialized)
struct StartChatTests {
    private let input: [UserInput] = [.text(.init(text: "Tidy the build scripts"))]

    private func connected(_ daemon: FakeDaemon) async -> HostConnection {
        let connection = daemon.connection()
        await connection.connect()
        return connection
    }

    private func started(_ id: String) -> ThreadStartResult {
        .init(thread: .init(threadId: id, status: .running, cwd: "/repo", lastSeq: 2))
    }

    @Test func theChatShowsBeforeTheHostAnswersAndTheEchoReplacesItsPrompt() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        await daemon.script.hold("thread/start")
        let pending = connection.prepareThread(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let model = pending.thread

        #expect(model.isStarting)
        #expect(model.items.map(\.id) == [pending.messageID])
        #expect(model.arrivedPrompt == pending.messageID)
        #expect(connection.chats.first === model)

        await daemon.script.queue("thread/start", started(model.id))
        let start = Task { try await connection.start(pending) }
        try await eventually { await !daemon.script.params(of: "thread/start").isEmpty }
        let params = try #require(await daemon.script.params(of: "thread/start").first)
        #expect(params["threadId"]?.stringValue == model.id)
        #expect(params["messageId"]?.stringValue == pending.messageID)

        // The host's echo, as it sends it before its answer.
        daemon.emit("turn/started", encoded(TurnStartedNotification(
            threadId: model.id, seq: 1, turn: .init(id: "turn", status: .inProgress, startedAt: 1))))
        daemon.emit("item/started", encoded(ItemStartedNotification(
            threadId: model.id, seq: 2, item: .userMessage(.init(id: pending.messageID, turnId: "turn", createdAt: 1, content: input)))))
        try await eventually { model.turns.count == 1 }
        await daemon.script.release("thread/start")

        let shown = try await start.value
        #expect(shown === model)
        #expect(!model.isStarting)
        #expect(!model.awaitingPrompt)
        #expect(model.items.map(\.id) == [pending.messageID])
        await connection.disconnect()
    }

    /// A host from before client-chosen ids makes its own: that chat is the one to show, and the
    /// one shown meanwhile goes.
    @Test func aHostThatPicksItsOwnIdGetsItsChatShown() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        await daemon.script.queue("thread/start", started("the-host-s"))
        let pending = connection.prepareThread(cwd: "/repo", input: input, options: .init(), defaults: nil)

        let shown = try await connection.start(pending)

        #expect(shown.id == "the-host-s")
        #expect(!connection.chats.contains { $0 === pending.thread })
        #expect(connection.thread(pending.thread.id) !== pending.thread)
        await connection.disconnect()
    }

    @Test func aChatThatDoesntStartGoes() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        let pending = connection.prepareThread(cwd: "/repo", input: input, options: .init(), defaults: nil)

        await #expect(throws: (any Error).self) { try await connection.start(pending) }

        #expect(!pending.thread.isStarting)
        #expect(!connection.chats.contains { $0 === pending.thread })
        await connection.disconnect()
    }

    /// The menus show what New Chat showed, not blanks, until the host says what it started with.
    @Test func theChatShowsTheSettingsItWasStartedWith() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        let pending = connection.prepareThread(cwd: "/repo", input: input, options: .init(effort: .high),
                                               defaults: .init(model: "opus", effort: .medium, permissionMode: .auto))
        #expect(pending.thread.model == "opus")
        #expect(pending.thread.effort == .high)
        #expect(pending.thread.permissionMode == .auto)
        #expect(pending.thread.cwd == "/repo")
        await connection.disconnect()
    }
}
