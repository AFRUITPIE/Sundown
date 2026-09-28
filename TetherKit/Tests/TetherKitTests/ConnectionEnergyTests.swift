import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// A daemon for connection tests: canned answers by method, every call counted, and a switch to
/// make the next connections fail.
private actor ScriptedDaemon {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(code: Int, message: String)
    }

    private(set) var calls: [String] = []
    private(set) var connects = 0
    private var replies: [String: Reply] = [:]
    /// Answers given once each, in order, before `replies`.
    private var queued: [String: [Reply]] = [:]
    /// The daemon's process: a new one says the daemon restarted.
    var pid = 1
    /// While true, a connection can't be made.
    var refusesConnections = false
    private var live: [FakeTransport] = []

    init() {
        replies["project/list"] = .result(["projects": []])
        replies["model/list"] = .result(encoded(ModelListResult(models: [.init(value: "sonnet", displayName: "Sonnet", description: "")])))
        replies["thread/list"] = .result(["threads": []])
        replies["account/read"] = .error(code: -1, message: "No account in the fixture")
        replies["command/list"] = .result(encoded(CommandListResult(commands: [.init(name: "review", description: "Review")])))
    }

    func set(_ method: String, _ reply: Reply) { replies[method] = reply }
    func enqueue(_ method: String, _ reply: Reply) { queued[method, default: []].append(reply) }
    func setPID(_ value: Int) { pid = value }
    func setRefusesConnections(_ value: Bool) { refusesConnections = value }
    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }
    func resetCalls() { calls = [] }

    /// The transport for the next connection, or a failure while connections are refused.
    func connect() throws -> any Transport {
        connects += 1
        if refusesConnections { throw TransportError.launchFailed("The fixture refuses connections") }
        let transport = FakeTransport(daemon: self)
        live.append(transport)
        return transport
    }

    /// The current connection, to push notifications down.
    func latest() -> FakeTransport? { live.last }

    func reply(method: String, params: JSONValue) -> Reply {
        calls.append(method)
        if method == "initialize" {
            return .result(encoded(InitializeResult(
                serverInfo: .init(name: "tether-server", version: "test"),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "fixture", platform: "linux", arch: "arm64", home: "/home/dev", pid: pid, mode: .daemon),
                claude: .init(path: "/usr/bin/claude", version: "test"))))
        }
        if var next = queued[method], !next.isEmpty {
            let reply = next.removeFirst()
            queued[method] = next
            return reply
        }
        return replies[method] ?? .error(code: -32601, message: "Not in the fixture")
    }
}

private final class FakeTransport: Transport, @unchecked Sendable {
    private let daemon: ScriptedDaemon
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(daemon: ScriptedDaemon) {
        self.daemon = daemon
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        let response: JSONValue = switch await daemon.reply(method: method, params: message["params"] ?? [:]) {
        case .result(let result): ["id": id, "result": result]
        case .error(let code, let text): ["id": id, "error": ["code": .number(Double(code)), "message": .string(text)]]
        }
        continuation.yield(try JSONEncoder().encode(response))
    }

    func close() async { continuation.finish() }

    func emit(method: String, params: JSONValue) {
        let notification: JSONValue = ["method": .string(method), "params": params]
        continuation.yield(try! JSONEncoder().encode(notification))
    }

    /// The connection drops, as when the daemon or the network goes away.
    func drop() { continuation.finish(throwing: TransportError.launchFailed("Dropped")) }
}

private enum WaitError: Error { case timeout }

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while await !condition() {
        if ContinuousClock.now > deadline { throw WaitError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private let sshHost = HostConfig(name: "Build box", kind: .ssh(destination: "build-box"))

@MainActor
private func connection(_ daemon: ScriptedDaemon, host: HostConfig = sshHost, network: NetworkPath? = nil) -> HostConnection {
    HostConnection(host: host, network: network, transportProvider: { _ in try await daemon.connect() })
}

private func summary(_ id: String, cwd: String) -> ThreadSummary {
    .init(threadId: id, title: id, cwd: cwd, updatedAt: 1, status: .idle)
}

private func page(_ texts: [String], hasMore: Bool) -> ScriptedDaemon.Reply {
    .result(encoded(ThreadReadResult(
        items: texts.map { .agentMessage(.init(id: $0, createdAt: 1, text: $0)) },
        turns: [], summary: nil, historySeq: nil, hasMore: hasMore)))
}

@Suite
struct ReconnectBackoffTests {
    /// Quick while it may be a blip, then less and less often: a host that stays away cost an SSH
    /// attempt every 30 s for as long as the app was open.
    @Test func quickAtFirstThenLessAndLessOften() {
        let waits = (1...14).map { ReconnectBackoff.delay(afterFailures: $0, jitter: 0.5) }
        #expect(Array(waits.prefix(4)) == [.seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        #expect(waits[4...7].allSatisfy { $0 == .seconds(30) })
        #expect(waits[8...11].allSatisfy { $0 == .seconds(5 * 60) })
        #expect(waits[12...].allSatisfy { $0 == .seconds(15 * 60) })
    }

    /// Spread by up to a fifth either way, so hosts that dropped together don't retry together.
    @Test func eachWaitIsSpreadByAFifth() {
        #expect(ReconnectBackoff.delay(afterFailures: 5, jitter: 0) == .seconds(24))
        #expect(ReconnectBackoff.delay(afterFailures: 5, jitter: 0.999_9) < .seconds(36))
        #expect(ReconnectBackoff.delay(afterFailures: 5, jitter: 0.999_9) > .seconds(35))
        // Out of range is clamped rather than trusted.
        #expect(ReconnectBackoff.delay(afterFailures: 1, jitter: -3) == .milliseconds(1_600))
        #expect(ReconnectBackoff.delay(afterFailures: 1, jitter: 7) == .milliseconds(2_400))
    }
}

@MainActor
@Suite(.serialized)
struct NetworkRetryTests {
    /// Off the network an SSH host isn't tried on a timer; it's tried as soon as the network is back.
    @Test func anSSHHostWaitsForTheNetworkRatherThanATimer() async throws {
        let daemon = ScriptedDaemon()
        await daemon.setRefusesConnections(true)
        let path = NetworkPath(monitoring: false)
        path.update(satisfied: false)
        let c = connection(daemon, network: path)

        await c.connect()
        guard case .failed = c.state else { Issue.record("expected a failure, got \(c.state)"); return }
        #expect(c.log.last == "Waiting for the network")
        #expect(c.reconnectAttempt == 0)

        await daemon.setRefusesConnections(false)
        path.update(satisfied: true, interfaces: ["en0"])
        try await eventually { c.state == .connected }
        #expect(await daemon.connects == 2)
        await c.disconnect()
    }

    /// A dropped connection waits before trying again; waking the Mac or Reconnect tries at once
    /// and starts the backoff over.
    @Test func retryNowTriesAtOnceAndStartsTheBackoffOver() async throws {
        let daemon = ScriptedDaemon()
        let c = connection(daemon)
        await c.connect()
        #expect(c.state == .connected)

        await daemon.setRefusesConnections(true)
        await daemon.latest()?.drop()
        try await eventually { if case .failed = c.state { true } else { false } }
        #expect(c.reconnectAttempt == 1)
        #expect(c.log.last?.hasPrefix("Trying again in") == true)

        c.retryNow()
        try await eventually { await daemon.connects == 2 }
        try await eventually { if case .failed = c.state { true } else { false } }
        // Started over: one failure since, not two.
        #expect(c.reconnectAttempt == 1)

        await daemon.setRefusesConnections(false)
        c.retryNow()
        try await eventually { c.state == .connected }
        #expect(c.reconnectAttempt == 0)
        // Nothing to retry on a connection that's up.
        c.retryNow()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await daemon.connects == 3)
        await c.disconnect()
    }

    /// This Mac's daemon is a process away: the network doesn't hold it back.
    @Test func thisMacDoesntWaitForTheNetwork() async throws {
        let daemon = ScriptedDaemon()
        await daemon.setRefusesConnections(true)
        let path = NetworkPath(monitoring: false)
        path.update(satisfied: false)
        let c = connection(daemon, host: .local, network: path)
        await c.connect()
        #expect(c.log.last?.hasPrefix("Trying again in") == true)
        #expect(c.reconnectAttempt == 1)
        await c.disconnect()
    }
}

@MainActor
@Suite(.serialized)
struct CatalogRefreshTests {
    /// Back on the same daemon, only the chats are asked for again: models and the account start
    /// a Claude Code process, and projects read every session. A restarted daemon gets all of it.
    @Test func reconnectingToTheSameDaemonAsksOnlyForTheChats() async throws {
        let daemon = ScriptedDaemon()
        let c = connection(daemon)
        await c.connect()
        #expect(await daemon.count("model/list") == 1)
        #expect(await daemon.count("project/list") == 1)
        #expect(!c.models.isEmpty)

        await daemon.resetCalls()
        await c.reconnect()
        #expect(await daemon.count("thread/list") == 1)
        #expect(await daemon.count("model/list") == 0)
        #expect(await daemon.count("account/read") == 0)
        #expect(await daemon.count("project/list") == 0)

        await daemon.setPID(2)
        await c.reconnect()
        #expect(await daemon.count("model/list") == 1)
        #expect(await daemon.count("project/list") == 1)
        await c.disconnect()
    }

    /// Folders of chats started while the app was away still reach New Chat's list.
    @Test func foldersNewSinceComeFromTheChats() async throws {
        let daemon = ScriptedDaemon()
        let c = connection(daemon)
        await c.connect()
        await daemon.set("thread/list", .result(encoded(ThreadListResult(threads: [summary("new", cwd: "/work/new")]))))
        await c.reconnect()
        #expect(c.projects.map(\.cwd) == ["/work/new"])
        await c.disconnect()
    }
}

@MainActor
@Suite(.serialized)
struct CommandCacheTests {
    /// Showing chats asks for no commands; looking for one asks once per folder, however many chats
    /// there are in it and however many ask at the same time.
    @Test func commandsAreAskedForOncePerFolderAndNeverForShowingAChat() async throws {
        let daemon = ScriptedDaemon()
        await daemon.set("thread/read", page(["m"], hasMore: false))
        let c = connection(daemon, host: .local)
        await c.connect()
        let a = c.thread("a"), b = c.thread("b"), other = c.thread("other")
        a.setSummary(summary("a", cwd: "/work/app"))
        b.setSummary(summary("b", cwd: "/work/app"))
        other.setSummary(summary("other", cwd: "/work/server"))

        for chat in [a, b, other, a, b] {
            await c.open(chat)
            c.leave(chat)
        }
        #expect(await daemon.count("command/list") == 0)
        #expect(c.cachedCommands(cwd: a.cwd, thread: a) == nil)

        async let first = c.commands(cwd: a.cwd, thread: a)
        async let second = c.commands(cwd: b.cwd, thread: b)
        let lists = await [first, second]
        #expect(lists.allSatisfy { $0.map(\.name) == ["review"] })
        #expect(await daemon.count("command/list") == 1)
        #expect(c.cachedCommands(cwd: b.cwd, thread: b)?.map(\.name) == ["review"])

        _ = await c.commands(cwd: a.cwd, thread: a)
        #expect(await daemon.count("command/list") == 1)
        _ = await c.commands(cwd: other.cwd, thread: other)
        #expect(await daemon.count("command/list") == 2)
        await c.disconnect()
    }

    /// A turn can add a command, and a new connection may be to a new daemon: either lets the
    /// lists go, as a plugin change does.
    @Test func aFinishedTurnAReconnectOrAPluginChangeAsksAgain() async throws {
        let daemon = ScriptedDaemon()
        let c = connection(daemon, host: .local)
        await c.connect()
        let a = c.thread("a"), other = c.thread("other")
        a.setSummary(summary("a", cwd: "/work/app"))
        other.setSummary(summary("other", cwd: "/work/server"))
        _ = await c.commands(cwd: a.cwd, thread: a)
        _ = await c.commands(cwd: other.cwd, thread: other)
        #expect(await daemon.count("command/list") == 2)

        await daemon.latest()?.emit(method: "turn/completed", params: [
            "threadId": "a", "seq": 1,
            "turn": encoded(Turn(id: "t1", status: .completed, startedAt: 1, completedAt: 2)),
        ])
        try await eventually { c.cachedCommands(cwd: a.cwd, thread: a) == nil }
        // Only that chat's folder.
        #expect(c.cachedCommands(cwd: other.cwd, thread: other) != nil)
        _ = await c.commands(cwd: a.cwd, thread: a)
        #expect(await daemon.count("command/list") == 3)

        await c.reconnect()
        #expect(c.cachedCommands(cwd: a.cwd, thread: a) == nil)
        _ = await c.commands(cwd: a.cwd, thread: a)
        #expect(await daemon.count("command/list") == 4)

        c.forgetCommands()
        #expect(c.cachedCommands(cwd: a.cwd, thread: a) == nil)
        await c.disconnect()
    }

    /// A failed request isn't kept: the next look asks again.
    @Test func aFailureIsNotKept() async throws {
        let daemon = ScriptedDaemon()
        await daemon.enqueue("command/list", .error(code: -1, message: "Claude Code didn't start"))
        let c = connection(daemon, host: .local)
        await c.connect()
        #expect(await c.commands(cwd: "/work/app").isEmpty)
        #expect(c.cachedCommands(cwd: "/work/app") == nil)
        #expect(await c.commands(cwd: "/work/app").map(\.name) == ["review"])
        await c.disconnect()
    }
}

@MainActor
@Suite(.serialized)
struct OlderHistoryTests {
    /// Each ask for an older page says how it went, so the transcript knows whether to ask again.
    @Test func anOlderPageSaysHowItWent() async throws {
        let daemon = ScriptedDaemon()
        await daemon.enqueue("thread/read", page(["m3"], hasMore: true))
        let c = connection(daemon, host: .local)
        await c.connect()
        let t = c.thread("t")
        t.setSummary(summary("t", cwd: "/work/app"))
        await c.open(t)
        #expect(t.hasMoreHistory)

        await daemon.enqueue("thread/read", .error(code: -1, message: "The host is busy"))
        #expect(await c.loadOlderHistory(t) == .failed)
        #expect(t.hasMoreHistory)

        t.loadingOlder = true
        #expect(await c.loadOlderHistory(t) == .busy)
        t.loadingOlder = false

        await c.disconnect()
        #expect(await c.loadOlderHistory(t) == .unavailable)

        await c.connect()
        await daemon.enqueue("thread/read", page(["m2"], hasMore: false))
        #expect(await c.loadOlderHistory(t) == .loaded)
        #expect(t.items.map(\.id) == ["m2", "m3"])
        #expect(await c.loadOlderHistory(t) == .complete)
        await c.disconnect()
    }
}

@Suite
struct SSHOptionsTests {
    @Test func keepalivesEveryThirtySeconds() {
        #expect(HostBootstrapper.sshOptions.contains("ServerAliveInterval=30"))
    }

    /// The check, the upload and the session share one SSH connection, through a socket in ~/.ssh.
    @Test func oneConnectionPerHostWhenThereIsASocketFolder() {
        let options = HostBootstrapper.sharedConnectionOptions(home: "/Users/hayden", isFolder: { $0 == "/Users/hayden/.ssh" })
        #expect(options == ["-o", "ControlMaster=auto", "-o", "ControlPath=/Users/hayden/.ssh/tether-%C", "-o", "ControlPersist=60"])
    }

    /// Where ssh couldn't make the socket it would stop rather than go on without it: no sharing.
    @Test func noSharingWhereSSHCouldntMakeTheSocket() {
        #expect(HostBootstrapper.sharedConnectionOptions(home: "/Users/hayden", isFolder: { _ in false }).isEmpty)
        let long = "/Users/" + String(repeating: "h", count: 40)
        #expect(HostBootstrapper.sharedConnectionOptions(home: long, isFolder: { _ in true }).isEmpty)
        #expect(HostBootstrapper.sharedConnectionOptions(home: "/Users/Jo Smith", isFolder: { _ in true }).isEmpty)
    }
}
