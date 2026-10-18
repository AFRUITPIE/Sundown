import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownFixtures
import SundownTestSupport

/// A daemon for connection tests: a model, no account, and a command.
private func makeDaemon() -> FakeHost {
    let host = FakeHost(hostname: "fixture")
    host.answer("model/list", with: ModelListResult(models: [.init(value: "sonnet", displayName: "Sonnet", description: "")]))
    host.fail("account/read", code: -1, "No account in the fixture")
    host.answer("command/list", with: CommandListResult(commands: [.init(name: "review", description: "Review")]))
    return host
}

private let sshHost = HostConfig(name: "Build box", kind: .ssh(destination: "build-box"))

@MainActor
private func connection(_ daemon: FakeHost, host: HostConfig = sshHost, network: NetworkPath? = nil) -> HostConnection {
    daemon.connection(host: host, network: network)
}

private func summary(_ id: String, cwd: String) -> ThreadSummary {
    .init(threadId: id, title: id, cwd: cwd, updatedAt: 1, status: .idle)
}

private func page(_ texts: [String], hasMore: Bool) -> FakeHost.Answer {
    .result(ThreadReadResult(
        items: texts.map { .agentMessage(.init(id: $0, createdAt: 1, text: $0)) },
        turns: [], summary: nil, historySeq: nil, hasMore: hasMore))
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
        let daemon = makeDaemon()
        daemon.refusesConnections = true
        let path = NetworkPath(monitoring: false)
        path.update(satisfied: false)
        let c = connection(daemon, network: path)

        await c.connect()
        #expect(c.state.failure != nil, "expected a failure, got \(c.state)")
        #expect(c.log.last == "Waiting for the network")
        #expect(c.reconnectAttempt == 0)

        daemon.refusesConnections = false
        path.update(satisfied: true, interfaces: ["en0"])
        try await eventually(timeout: .seconds(3)) { c.state == .connected }
        #expect(daemon.connects == 2)
        await c.disconnect()
    }

    /// A dropped connection waits before trying again; waking the Mac or Reconnect tries at once
    /// and starts the backoff over.
    @Test func retryNowTriesAtOnceAndStartsTheBackoffOver() async throws {
        let daemon = makeDaemon()
        let c = connection(daemon)
        await c.connect()
        #expect(c.state == .connected)

        daemon.refusesConnections = true
        daemon.drop()
        try await eventually(timeout: .seconds(3)) { if case .failed = c.state { true } else { false } }
        #expect(c.reconnectAttempt == 1)
        #expect(c.log.last?.hasPrefix("Trying again in") == true)

        c.retryNow()
        try await eventually(timeout: .seconds(3)) { daemon.connects == 2 }
        try await eventually(timeout: .seconds(3)) { if case .failed = c.state { true } else { false } }
        // Started over: one failure since, not two.
        #expect(c.reconnectAttempt == 1)

        daemon.refusesConnections = false
        c.retryNow()
        try await eventually(timeout: .seconds(3)) { c.state == .connected }
        #expect(c.reconnectAttempt == 0)
        // Nothing to retry on a connection that's up.
        c.retryNow()
        try await Task.sleep(for: .milliseconds(50))
        #expect(daemon.connects == 3)
        await c.disconnect()
    }

    /// This Mac's daemon is a process away: the network doesn't hold it back.
    @Test func thisMacDoesntWaitForTheNetwork() async throws {
        let daemon = makeDaemon()
        daemon.refusesConnections = true
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
    /// a Claude Code process. A restarted daemon gets all of it. Nothing reads every session.
    @Test func reconnectingToTheSameDaemonAsksOnlyForTheChats() async throws {
        let daemon = makeDaemon()
        let c = connection(daemon)
        await c.connect()
        #expect(daemon.count("model/list") == 1)
        #expect(!c.models.isEmpty)

        daemon.forgetCalls()
        await c.reconnect()
        #expect(daemon.count("thread/list") == 1)
        #expect(daemon.count("model/list") == 0)
        #expect(daemon.count("account/read") == 0)

        daemon.pid = 2
        await c.reconnect()
        #expect(daemon.count("model/list") == 1)
        await c.disconnect()
    }

    /// New Chat's directories are the chats' own, those started while the app was away included:
    /// nothing reads every session on the host for them.
    @Test func directoriesComeFromTheChats() async throws {
        let daemon = makeDaemon()
        let c = connection(daemon)
        await c.connect()
        daemon.answer("thread/list", with: ThreadListResult(threads: [summary("new", cwd: "/work/new")]))
        await c.reconnect()
        #expect(c.directories == ["/work/new"])
        #expect(daemon.count("project/list") == 0)
        await c.disconnect()
    }
}

@MainActor
@Suite(.serialized)
struct CommandCacheTests {
    /// Showing chats asks for no commands; looking for one asks once per folder, however many chats
    /// there are in it and however many ask at the same time.
    @Test func commandsAreAskedForOncePerFolderAndNeverForShowingAChat() async throws {
        let daemon = makeDaemon()
        daemon.answer("thread/read", page(["m"], hasMore: false))
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
        #expect(daemon.count("command/list") == 0)
        #expect(c.cachedCommands(cwd: a.cwd, thread: a) == nil)

        async let first = c.commands(cwd: a.cwd, thread: a)
        async let second = c.commands(cwd: b.cwd, thread: b)
        let lists = await [first, second]
        #expect(lists.allSatisfy { $0.map(\.name) == ["review"] })
        #expect(daemon.count("command/list") == 1)
        #expect(c.cachedCommands(cwd: b.cwd, thread: b)?.map(\.name) == ["review"])

        _ = await c.commands(cwd: a.cwd, thread: a)
        #expect(daemon.count("command/list") == 1)
        _ = await c.commands(cwd: other.cwd, thread: other)
        #expect(daemon.count("command/list") == 2)
        await c.disconnect()
    }

    /// A turn can add a command, and a new connection may be to a new daemon: either lets the
    /// lists go.
    @Test func aFinishedTurnOrAReconnectAsksAgain() async throws {
        let daemon = makeDaemon()
        let c = connection(daemon, host: .local)
        await c.connect()
        let a = c.thread("a"), other = c.thread("other")
        a.setSummary(summary("a", cwd: "/work/app"))
        other.setSummary(summary("other", cwd: "/work/server"))
        _ = await c.commands(cwd: a.cwd, thread: a)
        _ = await c.commands(cwd: other.cwd, thread: other)
        #expect(daemon.count("command/list") == 2)

        daemon.emit("turn/completed", [
            "threadId": "a", "seq": 1,
            "turn": json(Turn(id: "t1", status: .completed, startedAt: 1, completedAt: 2)),
        ])
        try await eventually(timeout: .seconds(3)) { c.cachedCommands(cwd: a.cwd, thread: a) == nil }
        // Only that chat's folder.
        #expect(c.cachedCommands(cwd: other.cwd, thread: other) != nil)
        _ = await c.commands(cwd: a.cwd, thread: a)
        #expect(daemon.count("command/list") == 3)

        await c.reconnect()
        #expect(c.cachedCommands(cwd: a.cwd, thread: a) == nil)
        _ = await c.commands(cwd: a.cwd, thread: a)
        #expect(daemon.count("command/list") == 4)

        await c.disconnect()
    }

    /// A failed request isn't kept: the next look asks again.
    @Test func aFailureIsNotKept() async throws {
        let daemon = makeDaemon()
        daemon.once("command/list", .error(code: -1, "Claude Code didn't start"))
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
        let daemon = makeDaemon()
        daemon.once("thread/read", page(["m3"], hasMore: true))
        let c = connection(daemon, host: .local)
        await c.connect()
        let t = c.thread("t")
        t.setSummary(summary("t", cwd: "/work/app"))
        await c.open(t)
        #expect(t.hasMoreHistory)

        daemon.once("thread/read", .error(code: -1, "The host is busy"))
        #expect(await c.loadOlderHistory(t) == .failed)
        #expect(t.hasMoreHistory)

        t.loadingOlder = true
        #expect(await c.loadOlderHistory(t) == .busy)
        t.loadingOlder = false

        await c.disconnect()
        #expect(await c.loadOlderHistory(t) == .unavailable)

        await c.connect()
        daemon.once("thread/read", page(["m2"], hasMore: false))
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
        #expect(options == ["-o", "ControlMaster=auto", "-o", "ControlPath=/Users/hayden/.ssh/sundown-%C", "-o", "ControlPersist=60"])
    }

    /// Where ssh couldn't make the socket it would stop rather than go on without it: no sharing.
    @Test func noSharingWhereSSHCouldntMakeTheSocket() {
        #expect(HostBootstrapper.sharedConnectionOptions(home: "/Users/hayden", isFolder: { _ in false }).isEmpty)
        let long = "/Users/" + String(repeating: "h", count: 40)
        #expect(HostBootstrapper.sharedConnectionOptions(home: long, isFolder: { _ in true }).isEmpty)
        #expect(HostBootstrapper.sharedConnectionOptions(home: "/Users/Jo Smith", isFolder: { _ in true }).isEmpty)
    }
}
