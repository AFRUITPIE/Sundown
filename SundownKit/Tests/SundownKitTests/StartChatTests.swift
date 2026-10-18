import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownFixtures
import SundownTestSupport

/// A chat started from New Chat shows at once in its window, as a stand-in (`PendingStart`), while
/// `thread/start` goes as ever. The host's chat is its own model, the one its notifications reach,
/// and the start is ready for the window to move to it once that chat holds the prompt the answer
/// names (`messageId`), which the host sends first, though the app may apply it after the answer.
@MainActor
@Suite(.serialized)
struct StartChatTests {
    private let input: [UserInput] = [.text(.init(text: "Tidy the build scripts"))]

    private func connected(_ host: FakeHost) async -> HostConnection {
        let connection = host.connection()
        await connection.connect()
        return connection
    }

    private func started(_ id: String, lastSeq: Int = 2, messageId: String? = "host-prompt") -> ThreadStartResult {
        .init(thread: .init(threadId: id, status: .running, cwd: "/repo", lastSeq: lastSeq), messageId: messageId, turnId: "turn")
    }

    /// The prompt's echo, as the host sends it: the turn, then the prompt with the host's own id.
    private func echo(_ host: FakeHost, in thread: String, text: String = "Tidy the build scripts", id: String = "host-prompt",
                      seq: Int = 1) {
        host.emit("turn/started", json(TurnStartedNotification(
            threadId: thread, seq: seq, turn: .init(id: "turn", status: .inProgress, startedAt: 1))))
        host.emit("item/started", json(ItemStartedNotification(
            threadId: thread, seq: seq + 1, item: .userMessage(.init(id: id, turnId: "turn", createdAt: 1,
                                                                     content: [.text(.init(text: text))])))))
    }

    private func prompts(in model: ThreadModel) -> [String] {
        model.items.compactMap { if case .userMessage(let m) = $0 { m.id } else { nil } }
    }

    @Test func theStandInIsNeverOneOfTheHostsChats() async throws {
        let host = FakeHost()
        let connection = await connected(host)
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
        let host = FakeHost()
        let connection = await connected(host)
        host.hold("thread/start")
        host.queue("thread/start", started("host-chat", lastSeq: 9))
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let start = Task { try await connection.start(op) }
        try await eventually { !host.calls(of: "thread/start").isEmpty }
        let params = try #require(host.calls(of: "thread/start").first)
        // `thread/start` as ever: no id of the client's.
        #expect(params["threadId"] == nil)
        #expect(params["messageId"] == nil)

        echo(host, in: "host-chat")
        try await eventually { connection.thread("host-chat").items.count == 1 }
        host.release("thread/start")
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

    /// A host set to name its chats asks for it with each start; any other leaves it to Claude Code.
    @Test func aHostThatNamesChatsAsksForATitle() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        host.queue("thread/start", started("plain-chat"), started("named-chat"))
        _ = try await connection.start(connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil))
        var config = connection.host
        config.namesChats = true
        connection.update(host: config)
        _ = try await connection.start(connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil))

        let params = host.calls(of: "thread/start")
        #expect(params.count == 2)
        #expect(params.first?["generateTitle"] == nil)
        #expect(params.last?["generateTitle"] == .bool(true))
        await connection.disconnect()
    }

    /// A host set to name its chats asks for it when a chat it isn't running is resumed too, so an
    /// older unnamed chat is named when it's opened (#103); any other host leaves it to Claude Code.
    @Test func aHostThatNamesChatsAsksForATitleOnResume() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        func resumed(_ id: String) -> ThreadResumeResult {
            .init(thread: .init(threadId: id, status: .idle, cwd: "/repo", lastSeq: 3), items: [], turns: [], historySeq: 3)
        }
        host.queue("thread/resume", resumed("plain-chat"), resumed("named-chat"))
        host.queue("thread/sideQuestion", ThreadSideQuestionResult(answer: "Nothing yet."))
        _ = try await connection.sideQuestion(connection.thread("plain-chat"), "What changed?")
        var config = connection.host
        config.namesChats = true
        connection.update(host: config)
        _ = try await connection.sideQuestion(connection.thread("named-chat"), "What changed?")

        let params = host.calls(of: "thread/resume")
        #expect(params.map { $0["threadId"]?.stringValue } == ["plain-chat", "named-chat"])
        #expect(params.first?["generateTitle"] == nil)
        #expect(params.last?["generateTitle"] == .bool(true), "thread/resume didn't ask for a title")
        await connection.disconnect()
    }

    /// A host saved before the setting existed still loads, not naming its chats.
    @Test func aHostSavedBeforeNamingLoads() throws {
        let saved = #"{"id":"00000000-0000-0000-0000-000000000002","name":"Work","kind":{"ssh":{"destination":"work"}},"env":{}}"#
        let host = try JSONDecoder().decode(HostConfig.self, from: Data(saved.utf8))
        #expect(host.name == "Work")
        #expect(host.sshDestination == "work")
        #expect(!host.namesChats)
        let again = try JSONDecoder().decode(HostConfig.self, from: JSONEncoder().encode(host))
        #expect(again == host)
    }

    /// The answer first: not ready until the echo, which isn't taken for a replay of what the
    /// answer's `lastSeq` covers.
    @Test func anEchoAfterTheAnswerIsStillApplied() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        host.queue("thread/start", started("host-chat", lastSeq: 9))
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)

        let chat = try await connection.start(op)
        #expect(!op.isReady)
        #expect(chat.lastSeq == 0)

        echo(host, in: "host-chat")
        await op.ready()
        #expect(op.echoID == "host-prompt")
        #expect(prompts(in: chat) == ["host-prompt"])
        #expect(chat.lastSeq == 2)
        await connection.disconnect()
    }

    /// The prompt the answer names is the echo, not whatever user message comes first; with no
    /// prompt named, the chat is ready as it is.
    @Test func theNamedPromptIsTheEcho() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        host.queue("thread/start", started("named-chat"), started("bare-chat", messageId: nil))

        let named = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        _ = try await connection.start(named)
        echo(host, in: "named-chat", text: "Something else", id: "other")
        try await eventually { connection.thread("named-chat").items.count == 1 }
        #expect(!named.isReady)
        echo(host, in: "named-chat", seq: 3)
        await named.ready()
        #expect(named.echoID == "host-prompt")

        let bare = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        _ = try await connection.start(bare)
        #expect(bare.isReady)
        #expect(bare.echoID == nil)
        await connection.disconnect()
    }

    /// The connection lost before the prompt came in: nothing more will come, so the window moves
    /// to the chat as it is.
    @Test func aStartWaitingWhenTheConnectionGoesIsReady() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        host.queue("thread/start", started("host-chat"))
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        _ = try await connection.start(op)
        #expect(!op.isReady)
        await connection.disconnect()
        #expect(op.isReady)
        #expect(op.echoID == nil)
    }

    /// Stop and a second message while the host hasn't answered reach the chat it started.
    @Test func stopAndASecondMessageReachTheStartedChat() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        host.hold("thread/start")
        host.queue("thread/start", started("host-chat"))
        host.queue("turn/start", TurnStartResult(turnId: "turn", messageId: "second", queued: true))
        host.queue("turn/interrupt", TurnInterruptResult())
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let start = Task { try await connection.start(op) }

        await connection.interrupt(op)
        let second = Task { await connection.send(op, input: [.text(.init(text: "And the tests"))]) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.calls(of: "turn/start").isEmpty)
        #expect(host.calls(of: "turn/interrupt").isEmpty)

        host.release("thread/start")
        _ = try await start.value
        #expect(await second.value)
        let sent = try #require(host.calls(of: "turn/start").first)
        #expect(sent["threadId"]?.stringValue == "host-chat")
        let interrupted = try #require(host.calls(of: "turn/interrupt").first)
        #expect(interrupted["threadId"]?.stringValue == "host-chat")
        await connection.disconnect()
    }

    /// A start that fails sends nothing more: a second message is handed back, and Stop has nothing
    /// to stop.
    @Test func aFailedStartSendsNothingMore() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        host.hold("thread/start")
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(), defaults: nil)
        let start = Task { try await connection.start(op) }
        await connection.interrupt(op)
        let second = Task { await connection.send(op, input: [.text(.init(text: "And the tests"))]) }
        try await Task.sleep(for: .milliseconds(50))
        // Not in the script: the daemon answers with an error.
        host.release("thread/start")

        await #expect(throws: (any Error).self) { try await start.value }
        #expect(await second.value == false)
        await op.ready()
        #expect(!op.isReady)
        #expect(op.thread == nil)
        #expect(host.calls(of: "turn/start").isEmpty)
        #expect(host.calls(of: "turn/interrupt").isEmpty)
        #expect(!connection.chats.contains { $0 === op.placeholder })
        await connection.disconnect()
    }

    /// The menus show what New Chat showed, not blanks, until the chat has started.
    @Test func theStandInShowsTheSettingsItWasStartedWith() async throws {
        let host = FakeHost()
        let connection = await connected(host)
        let op = connection.prepareStart(cwd: "/repo", input: input, options: .init(effort: .high),
                                         defaults: .init(model: "opus", effort: .medium, permissionMode: .auto))
        #expect(op.placeholder.model == "opus")
        #expect(op.placeholder.effort == .high)
        #expect(op.placeholder.permissionMode == .auto)
        #expect(op.placeholder.cwd == "/repo")
        await connection.disconnect()
    }
}
