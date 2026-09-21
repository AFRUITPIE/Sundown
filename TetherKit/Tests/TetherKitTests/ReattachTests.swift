import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

@MainActor
@Suite(.serialized)
struct ReattachTests {
    private let threadID = "long-running-ssh-thread"

    @Test func reconnectSubscribesAfterLastSeenSequenceAndKeepsModelIdentity() async throws {
        let firstScript = ReattachScript(
            reads: [readResult(text: "before", sequence: 40)],
            subscriptions: [subscribeResult(lastSequence: 40)]
        )
        let secondScript = ReattachScript(
            reads: [],
            subscriptions: [subscribeResult(lastSequence: 43)]
        )
        let firstTransport = ScriptedTransport(script: firstScript)
        let secondTransport = ScriptedTransport(script: secondScript)
        let connection = makeConnection(transports: [firstTransport, secondTransport])

        await connection.connect()
        let thread = connection.thread(threadID)
        thread.setSummary(summary())
        await connection.open(thread)
        firstTransport.emit(method: "item/agentMessage/delta", params: [
            "threadId": .string(threadID), "seq": 41, "itemId": "answer", "delta": " during",
        ])
        try await waitUntil { thread.lastSeq == 41 }

        let originalIdentity = ObjectIdentifier(thread)
        await connection.reconnect()

        #expect(ObjectIdentifier(connection.thread(threadID)) == originalIdentity)
        #expect(await secondScript.subscriptionSequences() == [41])

        secondTransport.emit(method: "item/agentMessage/delta", params: [
            "threadId": .string(threadID), "seq": 42, "itemId": "answer", "delta": " after",
        ])
        secondTransport.emit(method: "thread/status/changed", params: [
            "threadId": .string(threadID), "seq": 43, "status": "idle",
        ])
        try await waitUntil { thread.lastSeq == 43 }

        #expect(agentText(in: thread) == "before during after")
        #expect(thread.items.filter { $0.id == "answer" }.count == 1)
        #expect(thread.status == .idle)
        await connection.disconnect()
    }

    @Test func restartedFollowerReloadsSnapshotBeforeResubscribing() async throws {
        let firstScript = ReattachScript(
            reads: [readResult(text: "before", sequence: 40)],
            subscriptions: [subscribeResult(lastSequence: 40)]
        )
        let restartedScript = ReattachScript(
            reads: [readResult(text: "complete remote transcript", sequence: 100)],
            subscriptions: [subscribeResult(lastSequence: 0), subscribeResult(lastSequence: 100)]
        )
        let firstTransport = ScriptedTransport(script: firstScript)
        let restartedTransport = ScriptedTransport(script: restartedScript)
        let connection = makeConnection(transports: [firstTransport, restartedTransport])

        await connection.connect()
        let thread = connection.thread(threadID)
        thread.setSummary(summary())
        await connection.open(thread)
        firstTransport.emit(method: "item/agentMessage/delta", params: [
            "threadId": .string(threadID), "seq": 41, "itemId": "answer", "delta": " during",
        ])
        try await waitUntil { thread.lastSeq == 41 }

        await connection.reconnect()

        #expect(await restartedScript.subscriptionSequences() == [41, 100])
        #expect(thread.lastSeq == 100)
        #expect(agentText(in: thread) == "complete remote transcript")
        #expect(thread.items.filter { $0.id == "answer" }.count == 1)
        await connection.disconnect()
    }

    @Test func leavingAFollowedThreadReleasesIt() async throws {
        let script = ReattachScript(
            reads: [readResult(text: "watched", sequence: 12)],
            subscriptions: [subscribeResult(lastSequence: 12, status: .notLoaded)]
        )
        let connection = makeConnection(transports: [ScriptedTransport(script: script)])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        #expect(thread.isFollowed)
        #expect(!connection.isLoaded(thread))

        connection.leave(thread)

        #expect(!thread.historyLoaded)
        #expect(thread.items.isEmpty)
            try await waitUntilAsync { await script.calls().contains("thread/unsubscribe") }
        await connection.disconnect()
    }

    @Test func sendingIntoAFollowedThreadResumesItInItsOwnSequence() async throws {
        let script = ReattachScript(
            reads: [readResult(text: "watched", sequence: 500)],
            subscriptions: [subscribeResult(lastSequence: 500, status: .notLoaded)],
            resume: .init(thread: .init(threadId: threadID, status: .idle, cwd: "/work/project", lastSeq: 3),
                          items: [.agentMessage(.init(id: "answer", createdAt: 1, text: "resumed"))],
                          turns: [], historySeq: 3, hasMore: true)
        )
        let transport = ScriptedTransport(script: script)
        let connection = makeConnection(transports: [transport])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)

        await connection.send(thread, input: [.text(.init(text: "hi"))])

        #expect(await script.resumeLimits() == [HostConnection.initialHistoryLimit])
        #expect(thread.lastSeq == 3)
        #expect(thread.hasMoreHistory)
        #expect(!thread.isFollowed)
        // The live thread's events start after 3, far below the follower's 500.
        transport.emit(method: "thread/status/changed", params: [
            "threadId": .string(threadID), "seq": 4, "status": "running",
        ])
        try await waitUntil { thread.status == .running }
        await connection.disconnect()
    }

    @Test func settingsChosenForAnUnloadedThreadApplyWhenItResumes() async throws {
        let script = ReattachScript(
            reads: [readResult(text: "watched", sequence: 7)],
            subscriptions: [subscribeResult(lastSequence: 7, status: .notLoaded)],
            resume: .init(thread: .init(threadId: threadID, status: .idle, cwd: "/work/project",
                                        model: "claude-sonnet-5", lastSeq: 1),
                          items: [], turns: [], historySeq: 1)
        )
        let connection = makeConnection(transports: [ScriptedTransport(script: script)])
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)

        await connection.setModel(thread, "claude-sonnet-5")
        await connection.setEffort(thread, .low)

        #expect(thread.lastError == nil)
        #expect(thread.model == "claude-sonnet-5")
        #expect(thread.effort == .low)
        #expect(!(await script.calls().contains("thread/setModel")))

        await connection.send(thread, input: [.text(.init(text: "hi"))])

        #expect(await script.resumeParams().first?["model"]?.stringValue == "claude-sonnet-5")
        #expect(await script.resumeParams().first?["effort"]?.stringValue == "low")
        #expect(thread.pendingSettings == PendingSettings())
        await connection.disconnect()
    }

    private func makeConnection(transports: [ScriptedTransport]) -> HostConnection {
        let queue = TransportQueue(transports)
        return HostConnection(
            host: HostConfig(name: "SSH fixture", kind: .ssh(destination: "claude-box")),
            transportProvider: { _ in try await queue.next() }
        )
    }

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

    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition() {
            if ContinuousClock.now > deadline { throw ReattachTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            if ContinuousClock.now > deadline { throw ReattachTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum ReattachTestError: Error {
    case noTransport
    case timeout
}

private actor TransportQueue {
    private var transports: [ScriptedTransport]

    init(_ transports: [ScriptedTransport]) {
        self.transports = transports
    }

    func next() throws -> any Transport {
        guard !transports.isEmpty else { throw ReattachTestError.noTransport }
        return transports.removeFirst()
    }
}

private actor ReattachScript {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(code: Int, message: String)
    }

    private var reads: [ThreadReadResult]
    private var subscriptions: [ThreadSubscribeResult]
    private var afterSequences: [Int?] = []
    private var resume: ThreadResumeResult?
    private var resumeLimitValues: [Int?] = []
    private var resumeParamValues: [JSONValue] = []
    private var methods: [String] = []

    init(reads: [ThreadReadResult], subscriptions: [ThreadSubscribeResult], resume: ThreadResumeResult? = nil) {
        self.reads = reads
        self.subscriptions = subscriptions
        self.resume = resume
    }

    func reply(method: String, params: JSONValue) -> Reply {
        methods.append(method)
        switch method {
        case "initialize":
            return .result(json(InitializeResult(
                serverInfo: .init(name: "tether-server", version: "test"),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "claude-box", platform: "linux", arch: "arm64", home: "/home/dev", pid: 1, mode: .daemon),
                claude: .init(path: "/usr/bin/claude", version: "test")
            )))
        case "thread/read":
            guard !reads.isEmpty else { return .error(code: -1, message: "Unexpected thread/read") }
            return .result(json(reads.removeFirst()))
        case "thread/subscribe":
            afterSequences.append(params["afterSeq"]?.intValue)
            guard !subscriptions.isEmpty else { return .error(code: -1, message: "Unexpected thread/subscribe") }
            return .result(json(subscriptions.removeFirst()))
        case "thread/unsubscribe": return .result([:])
        case "thread/resume":
            resumeLimitValues.append(params["limit"]?.intValue)
            resumeParamValues.append(params)
            guard let resume else { return .error(code: -1, message: "Unexpected thread/resume") }
            return .result(json(resume))
        case "turn/start": return .result(json(TurnStartResult(turnId: "t", messageId: "m", queued: false)))
        case "project/list": return .result(["projects": []])
        case "model/list": return .result(["models": []])
        case "thread/list": return .result(["threads": []])
        default: return .error(code: -32601, message: "Not implemented in fixture")
        }
    }

    func subscriptionSequences() -> [Int?] { afterSequences }
    func resumeLimits() -> [Int?] { resumeLimitValues }
    func calls() -> [String] { methods }
    func resumeParams() -> [JSONValue] { resumeParamValues }
}

private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let script: ReattachScript
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(script: ReattachScript) {
        self.script = script
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        let response: JSONValue
        switch await script.reply(method: method, params: message["params"] ?? [:]) {
        case .result(let result):
            response = ["id": id, "result": result]
        case .error(let code, let message):
            response = ["id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
        }
        continuation.yield(try JSONEncoder().encode(response))
    }

    func close() async {
        continuation.finish()
    }

    func emit(method: String, params: JSONValue) {
        let notification: JSONValue = ["method": .string(method), "params": params]
        continuation.yield(try! JSONEncoder().encode(notification))
    }
}

private func json<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
