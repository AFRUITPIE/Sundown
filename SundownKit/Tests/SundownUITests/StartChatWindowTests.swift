import Foundation
@testable import SundownFixtures
import Testing
import TetherProtocol
@testable import SundownKit
@testable import SundownUI
import SundownFixtures
import SundownTestSupport

/// New Chat's Send, as a window sees it: the start shows in New Chat's place at once, the window
/// moves to the host's chat once it has started, and what's done meanwhile (Stop, another message,
/// the menus, going elsewhere, a failure) ends up where it belongs.
@MainActor
@Suite(.serialized)
struct StartChatWindowTests {
    private let prompt: [UserInput] = [.text(.init(text: "Tidy the build scripts"))]

    private func setUp(_ host: FakeHost) async -> (WindowModel, HostConnection) {
        let connection = host.connection(host: HostConfig(name: "Starting", kind: .ssh(destination: "starting.invalid")))
        await connection.connect()
        let window = WindowModel(app: .sample(connections: [connection]), target: WindowTarget(hostID: connection.id))
        window.start()
        window.draftDirectory = "/repo"
        return (window, connection)
    }

    private var newChatKey: (WindowModel) -> String { { "new-chat:\($0.hostID)" } }

    @Test func theWindowShowsTheStartThenMovesToTheChat() async throws {
        let host = startingHost(holdsStart: true)
        let (window, connection) = await setUp(host)
        let target = window.target(keeping: UUID())
        let send = Task { await window.startDraftChat(prompt) }
        try await eventually { window.starting != nil }

        // New Chat, showing the stand-in: no chat of the host's, and the scene value still New Chat.
        #expect(window.threadID == nil)
        #expect(window.selectedThread == nil)
        #expect(window.title == "Tidy the build scripts")
        #expect(window.starting?.placeholder.isStarting == true)
        // Typed while it starts: the chat's draft once the window moves there.
        window.app.setDraft("Then run the tests", for: newChatKey(window))

        host.release("thread/start")
        #expect(await send.value)
        let chat = try #require(window.selectedThread)
        #expect(chat.id == "host-chat")
        #expect(chat === connection.thread("host-chat"))
        #expect(window.starting == nil)
        #expect(window.target(keeping: target.id).id == target.id)
        #expect(window.target(keeping: target.id).threadID == "host-chat")
        #expect(chat.items.count == 1)
        // The prompt already flew here: its echo doesn't fly or fade in again.
        #expect(window.sendGeometry.landedPrompt == "host-prompt")
        #expect(window.app.draft(for: "host-chat") == "Then run the tests")
        #expect(window.app.draft(for: newChatKey(window)).isEmpty)
        await connection.disconnect()
    }

    /// Stop and another message, both before the host answers, reach the chat it started.
    @Test func stopAndASecondMessageDuringTheStartReachTheChat() async throws {
        let host = startingHost(holdsStart: true)
        let (window, connection) = await setUp(host)
        let send = Task { await window.startDraftChat(prompt) }
        try await eventually { window.starting != nil }

        window.stopStarting()
        let second = Task { await window.startDraftChat([.text(.init(text: "And the tests"))]) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.calls(of: "turn/start").isEmpty)
        #expect(host.calls(of: "turn/interrupt").isEmpty)

        host.release("thread/start")
        #expect(await send.value)
        #expect(await second.value)
        try await eventually { !host.calls(of: "turn/interrupt").isEmpty }
        #expect(host.calls(of: "turn/start").map { $0["threadId"]?.stringValue } == ["host-chat"])
        #expect(host.calls(of: "turn/interrupt").map { $0["threadId"]?.stringValue } == ["host-chat"])
        #expect(host.calls(of: "thread/start").count == 1)
        await connection.disconnect()
    }

    /// Nothing picked, nothing sent: the host's Claude Code starts the chat with its own model,
    /// effort and permission mode, even while New Chat's menus show them (#58, #71).
    @Test func aChatStartsWithClaudeCodesOwnSettings() async throws {
        let host = startingHost()
        let (window, connection) = await setUp(host)
        window.newChat()
        window.draftDirectory = "/repo"
        window.draftDefaults = .init(model: "sonnet", effort: .medium, permissionMode: .auto)

        #expect(await window.startDraftChat(prompt))

        let params = try #require(host.calls(of: "thread/start").first)
        for key in ["model", "effort", "permissionMode"] {
            #expect(params[key] == nil || params[key] == .null, "thread/start sent \(key) though nobody picked one: \(params[key]!)")
        }
        await connection.disconnect()
    }

    /// The menus changed while it starts are the chat's settings once it has.
    @Test func settingsChangedDuringTheStartApplyToTheChat() async throws {
        let host = startingHost(holdsStart: true)
        let (window, connection) = await setUp(host)
        window.draftEffort = .low
        let send = Task { await window.startDraftChat(prompt) }
        try await eventually { window.starting != nil }

        window.draftModel = "opus"
        window.draftEffort = .high
        window.draftPermissionMode = .plan
        window.draftFastMode = true
        host.release("thread/start")
        #expect(await send.value)

        #expect(host.calls(of: "thread/start").first?["effort"]?.stringValue == "low")
        #expect(host.calls(of: "thread/setModel").map { $0["model"]?.stringValue } == ["opus"])
        #expect(host.calls(of: "thread/setEffort").map { $0["effort"]?.stringValue } == ["high"])
        #expect(host.calls(of: "thread/setPermissionMode").map { $0["mode"]?.stringValue } == ["plan"])
        #expect(host.calls(of: "thread/setFastMode").map { $0["enabled"]?.boolValue } == [true])
        for method in ["thread/setModel", "thread/setEffort", "thread/setPermissionMode", "thread/setFastMode"] {
            #expect(host.calls(of: method).allSatisfy { $0["threadId"]?.stringValue == "host-chat" }, "\(method)")
        }
        await connection.disconnect()
    }

    /// A start that fails leaves the window on New Chat, saying why, with its settings, and hands
    /// the prompt back to the field it came from, which puts it after anything typed since; New
    /// Chat's draft isn't written over.
    @Test func aFailedStartHandsItsPromptBackWithoutWritingOverANewerDraft() async throws {
        let host = startingHost(holdsStart: true, failsStart: true)
        let (window, connection) = await setUp(host)
        window.draftModel = "opus"
        window.draftWorktree = true
        let send = Task { await window.startDraftChat(prompt) }
        try await eventually { window.starting != nil }
        window.app.setDraft("Something newer", for: newChatKey(window))

        host.release("thread/start")
        #expect(await send.value == false)
        #expect(window.starting == nil)
        #expect(window.threadID == nil)
        #expect(window.draftError != nil)
        #expect(window.draftModel == "opus")
        #expect(window.draftWorktree)
        #expect(window.draftDirectory == "/repo")
        #expect(window.app.draft(for: newChatKey(window)) == "Something newer")
        // What the field does with it: the newer draft first, nothing lost.
        #expect(Composer.puttingBack("Tidy the build scripts", into: "Something newer") == "Something newer\n\nTidy the build scripts")
        #expect(Composer.puttingBack("Tidy the build scripts", into: "") == "Tidy the build scripts")
        await connection.disconnect()
    }

    /// Gone to another chat meanwhile, the window isn't taken back; and a start that then fails puts
    /// its prompt in New Chat's draft only if that's empty, since the field it came from is gone.
    @Test func aWindowThatWentElsewhereIsntTakenBack() async throws {
        let host = startingHost(holdsStart: true)
        let (window, connection) = await setUp(host)
        let other = WindowModel(app: window.app, target: WindowTarget(hostID: connection.id))
        other.start()
        let send = Task { await window.startDraftChat(prompt) }
        try await eventually { window.starting != nil }
        #expect(other.starting == nil)

        window.open(threadID: "elsewhere")
        #expect(window.starting == nil)
        host.release("thread/start")
        #expect(await send.value)
        #expect(window.threadID == "elsewhere")
        #expect(other.threadID == nil)
        #expect(other.selectedThread == nil)
        // The chat is there to go to.
        #expect(connection.chats.contains { $0.id == "host-chat" })
        await connection.disconnect()

        let failing = startingHost(holdsStart: true, failsStart: true)
        let (left, failingConnection) = await setUp(failing)
        let failed = Task { await left.startDraftChat(prompt) }
        try await eventually { left.starting != nil }
        left.open(threadID: "elsewhere")
        failing.release("thread/start")
        #expect(await failed.value)
        #expect(left.app.draft(for: newChatKey(left)) == "Tidy the build scripts")
        await failingConnection.disconnect()
    }

    /// New Chat pressed while it starts: a new draft, which the chat doesn't take over.
    @Test func newChatDuringTheStartStaysOnNewChat() async throws {
        let host = startingHost(holdsStart: true)
        let (window, connection) = await setUp(host)
        let send = Task { await window.startDraftChat(prompt) }
        try await eventually { window.starting != nil }
        window.newChat()
        host.release("thread/start")
        #expect(await send.value)
        #expect(window.threadID == nil)
        #expect(window.starting == nil)
        await connection.disconnect()
    }

    @Test func aLostConnectionSaysTheChatMayHaveStarted() {
        let message = WindowModel.startFailure(TransportError.closed(exitCode: 0, stderr: ""))
        #expect(message.contains("may have started"))
        #expect(WindowModel.startFailure(RPCError(code: 1, message: "No such directory")) == "No such directory")
    }

}

/// A host that starts chats as the daemon does: the prompt's echo, then the answer. Its answer to
/// `thread/start` can wait to be released, or be an error.
private func startingHost(holdsStart: Bool = false, failsStart: Bool = false) -> FakeHost {
    let host = FakeHost(hostname: "starting")
    if holdsStart { host.hold("thread/start") }
    if failsStart {
        host.fail("thread/start", code: -32000, "No such directory: /repo")
    } else {
        host.answer("thread/start") { call in
            let text = call.params["input"]?.arrayValue?.first?["text"] ?? "Prompt"
            call.emit("turn/started", json(TurnStartedNotification(
                threadId: "host-chat", seq: 1, turn: .init(id: "turn", status: .inProgress, startedAt: 1))))
            call.emit("item/started", ["threadId": "host-chat", "seq": 2, "item": [
                "type": "userMessage", "id": "host-prompt", "turnId": "turn", "createdAt": 1,
                "content": [["type": "text", "text": text]],
            ]])
            return .result(ThreadStartResult(thread: .init(threadId: "host-chat", status: .running, cwd: "/repo", lastSeq: 2),
                                             messageId: "host-prompt", turnId: "turn"))
        }
    }
    host.answer("turn/start", with: TurnStartResult(turnId: "turn", messageId: "second", queued: true))
    for method in ["turn/interrupt", "thread/setModel", "thread/setEffort", "thread/setPermissionMode", "thread/setFastMode"] {
        host.answer(method, .result([:]))
    }
    return host
}
