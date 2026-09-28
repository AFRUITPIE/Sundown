import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// A daemon for connection tests: canned answers by method, every call counted, and a switch to
/// make the next connections fail.
private actor FakeDaemon {
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
    private let daemon: FakeDaemon
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(daemon: FakeDaemon) {
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

private func encoded<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
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
private func connection(_ daemon: FakeDaemon, host: HostConfig = sshHost, network: NetworkPath? = nil) -> HostConnection {
    HostConnection(host: host, network: network, transportProvider: { _ in try await daemon.connect() })
}

private func summary(_ id: String, cwd: String) -> ThreadSummary {
    .init(threadId: id, title: id, cwd: cwd, updatedAt: 1, status: .idle)
}

private func page(_ texts: [String], hasMore: Bool) -> FakeDaemon.Reply {
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
        let daemon = FakeDaemon()
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
        let daemon = FakeDaemon()
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
        let daemon = FakeDaemon()
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
