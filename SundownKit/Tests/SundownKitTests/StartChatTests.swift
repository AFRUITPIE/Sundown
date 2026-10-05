import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// A chat started from New Chat shows at once in its window, as a stand-in (`PendingStart`), while
/// `thread/start` goes as ever. The host's chat is its own model, the one its notifications reach,
/// and the start is ready for the window to move to it once that chat has the prompt's echo,
/// whichever of the echo and the answer comes first.
@MainActor
@Suite(.serialized)
struct StartChatTests {
    private let input: [UserInput] = [.text(.init(text: "Tidy the build scripts"))]

    private func connected(_ daemon: FakeDaemon) async -> HostConnection {
        let connection = daemon.connection()
        await connection.connect()
        return connection
    }

    private func started(_ id: String, lastSeq: Int = 2) -> ThreadStartResult {
        .init(thread: .init(threadId: id, status: .running, cwd: "/repo", lastSeq: lastSeq))
    }

    /// The prompt's echo, as the host sends it: the turn, then the prompt with the host's own id.
    private func echo(_ daemon: FakeDaemon, in thread: String, text: String = "Tidy the build scripts", id: String = "host-prompt") {
        daemon.emit("turn/started", encoded(TurnStartedNotification(
            threadId: thread, seq: 1, turn: .init(id: "turn", status: .inProgress, startedAt: 1))))
        daemon.emit("item/started", encoded(ItemStartedNotification(
            threadId: thread, seq: 2, item: .userMessage(.init(id: id, turnId: "turn", createdAt: 1,
                                                               content: [.text(.init(text: text))])))))
    }

    private func prompts(in model: ThreadModel) -> [String] {
        model.items.compactMap { if case .userMessage(let m) = $0 { m.id } else { nil } }
    }

    @Test func theStandInIsNeverOneOfTheHostsChats() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)

        #expect(op.placeholder.isStarting)
        #expect(op.placeholder.items.map(\.id) == [op.promptID])
        #expect(op.placeholder.arrivedPrompt == op.promptID)
        #expect(op.placeholder.lastSeq == 0)
        #expect(!connection.chats.contains { $0 === op.placeholder })
        #expect(connection.thread(op.placeholder.id) !== op.placeholder)
        await connection.disconnect()
    }

    /// The host's echo comes before its answer, as the daemon sends them: the chat it reached is the
    /// one started, with one prompt, the host's, and its sequence where the events left it.
    @Test func anEchoBeforeTheAnswerIsTheChatsOnlyPrompt() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        await daemon.script.hold("thread/start")
        await daemon.script.queue("thread/start", started("host-chat", lastSeq: 9))
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let start = Task { try await connection.start(op) }
        try await eventually { await !daemon.script.params(of: "thread/start").isEmpty }
        let params = try #require(await daemon.script.params(of: "thread/start").first)
        // `thread/start` as ever: no id of the client's.
        #expect(params["threadId"] == nil)
        #expect(params["messageId"] == nil)

        echo(daemon, in: "host-chat")
        try await eventually { connection.thread("host-chat").items.count == 1 }
        await daemon.script.release("thread/start")
        let chat = try await start.value

        #expect(chat === connection.thread("host-chat"))
        #expect(prompts(in: chat) == ["host-prompt"])
        #expect(op.isReady)
        #expect(op.echoID == "host-prompt")
        #expect(!op.placeholder.isStarting)
        // What was applied, not what the answer said.
        #expect(chat.lastSeq == 2)
        #expect(connection.chats.contains { $0 === chat })
        #expect(!connection.chats.contains { $0 === op.placeholder })
        await connection.disconnect()
    }

    /// The answer first: not ready until the echo, which isn't taken for a replay of what the
    /// answer's `lastSeq` covers.
    @Test func anEchoAfterTheAnswerIsStillApplied() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        await daemon.script.queue("thread/start", started("host-chat", lastSeq: 9))
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)

        let chat = try await connection.start(op)
        #expect(!op.isReady)
        #expect(chat.lastSeq == 0)

        echo(daemon, in: "host-chat")
        await op.ready()
        #expect(op.echoID == "host-prompt")
        #expect(prompts(in: chat) == ["host-prompt"])
        #expect(chat.lastSeq == 2)
        await connection.disconnect()
    }

    /// No echo: the window moves to the chat after a moment anyway. A first prompt that doesn't say
    /// what was sent isn't taken for the echo.
    @Test func withoutAnEchoTheStartIsReadyAfterAMoment() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        connection.echoWait = .milliseconds(50)
        await daemon.script.queue("thread/start", started("quiet-chat"), started("other-chat"))

        let quiet = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        _ = try await connection.start(quiet)
        await quiet.ready()
        #expect(quiet.isReady)
        #expect(quiet.echoID == nil)

        let other = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        _ = try await connection.start(other)
        echo(daemon, in: "other-chat", text: "Something else")
        await other.ready()
        #expect(other.echoID == nil)
        await connection.disconnect()
    }

    /// Stop and a second message while the host hasn't answered reach the chat it started.
    @Test func stopAndASecondMessageReachTheStartedChat() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        await daemon.script.hold("thread/start")
        await daemon.script.queue("thread/start", started("host-chat"))
        await daemon.script.queue("turn/start", TurnStartResult(turnId: "turn", messageId: "second", queued: true))
        await daemon.script.queue("turn/interrupt", TurnInterruptResult())
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let start = Task { try await connection.start(op) }

        await connection.interrupt(op)
        let second = Task { await connection.send(op, input: [.text(.init(text: "And the tests"))]) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await daemon.script.params(of: "turn/start").isEmpty)
        #expect(await daemon.script.params(of: "turn/interrupt").isEmpty)

        await daemon.script.release("thread/start")
        _ = try await start.value
        #expect(await second.value)
        let sent = try #require(await daemon.script.params(of: "turn/start").first)
        #expect(sent["threadId"]?.stringValue == "host-chat")
        let interrupted = try #require(await daemon.script.params(of: "turn/interrupt").first)
        #expect(interrupted["threadId"]?.stringValue == "host-chat")
        await connection.disconnect()
    }

    /// A start that fails sends nothing more: a second message is handed back, and Stop has nothing
    /// to stop.
    @Test func aFailedStartSendsNothingMore() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        await daemon.script.hold("thread/start")
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let start = Task { try await connection.start(op) }
        await connection.interrupt(op)
        let second = Task { await connection.send(op, input: [.text(.init(text: "And the tests"))]) }
        try await Task.sleep(for: .milliseconds(50))
        // Not in the script: the daemon answers with an error.
        await daemon.script.release("thread/start")

        await #expect(throws: (any Error).self) { try await start.value }
        #expect(await second.value == false)
        await op.ready()
        #expect(!op.isReady)
        #expect(op.thread == nil)
        #expect(await daemon.script.params(of: "turn/start").isEmpty)
        #expect(await daemon.script.params(of: "turn/interrupt").isEmpty)
        #expect(!connection.chats.contains { $0 === op.placeholder })
        await connection.disconnect()
    }

    /// The menus show what New Chat showed, not blanks, until the chat has started.
    @Test func theStandInShowsTheSettingsItWasStartedWith() async throws {
        let daemon = FakeDaemon()
        let connection = await connected(daemon)
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(effort: .high),
                                         defaults: .init(model: "opus", effort: .medium, permissionMode: .auto))
        #expect(op.placeholder.model == "opus")
        #expect(op.placeholder.effort == .high)
        #expect(op.placeholder.permissionMode == .auto)
        #expect(op.placeholder.cwd == "/repo")
        await connection.disconnect()
    }

    @Test func anEchoSaysWhatWasSent() {
        let sent: [UserInput] = [.text(.init(text: "  Hello\n"))]
        #expect(PendingStart.says([.text(.init(text: "Hello"))], as: sent))
        #expect(!PendingStart.says([.text(.init(text: "Goodbye"))], as: sent))
        let image: [UserInput] = [.image(.init(mediaType: .imagePng, data: "AAAA"))]
        #expect(PendingStart.says(image, as: image))
        #expect(!PendingStart.says([], as: image))
    }
}
