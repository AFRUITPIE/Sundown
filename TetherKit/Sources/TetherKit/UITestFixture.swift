#if DEBUG
import Foundation
import TetherProtocol

/// A process-free JSON-RPC server for XCTest UI runs. The only entry point is the explicit
/// TETHER_UI_TEST_MODE launch path; unhandled methods return an error instead of reaching Claude.
public enum UITestFixture {
    public static let threadID = "fixture-thread"

    @MainActor
    public static func connection(host: HostConfig = .local, failFirstConnect: Bool = false,
                                  pendingPermission: Bool = false) -> HostConnection {
        let attempts = FixtureAttempts()
        return HostConnection(host: host, transportProvider: { _ in
            if failFirstConnect, await attempts.next() == 1 {
                throw TransportError.launchFailed("Fixture connection unavailable")
            }
            return FixtureTransport(pendingPermission: pendingPermission)
        })
    }
}

private actor FixtureAttempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private final class FixtureTransport: Transport, @unchecked Sendable {
    private let script: FixtureScript
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(pendingPermission: Bool) {
        script = FixtureScript(pendingPermission: pendingPermission)
        var captured: AsyncThrowingStream<Data, any Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = request["id"], let method = request["method"]?.stringValue else { return }
        let reply = await script.reply(method: method, params: request["params"] ?? [:])
        let response: JSONValue
        switch reply.value {
        case .result(let result): response = ["id": id, "result": result]
        case .error(let message):
            response = ["id": id, "error": ["code": -32601, "message": .string(message)]]
        }
        continuation.yield(try JSONEncoder().encode(response))
        for (name, params) in reply.notifications {
            let notification: JSONValue = ["method": .string(name), "params": params]
            continuation.yield(try JSONEncoder().encode(notification))
        }
        for (id, method, params) in reply.requests {
            let request: JSONValue = ["id": id, "method": .string(method), "params": params]
            continuation.yield(try JSONEncoder().encode(request))
        }
    }

    func close() async { continuation.finish() }
}

private actor FixtureScript {
    enum Value: Sendable { case result(JSONValue), error(String) }
    struct Reply: Sendable {
        let value: Value
        var notifications: [(String, JSONValue)] = []
        var requests: [(JSONValue, String, JSONValue)] = []
    }

    private let pendingPermission: Bool
    private var sentPermission = false
    private var nextSequence = 1
    private var nextMessage = 0
    private var additionalThreads: [ThreadSummary] = []

    init(pendingPermission: Bool) {
        self.pendingPermission = pendingPermission
    }

    private var originalSummary: ThreadSummary {
        .init(threadId: UITestFixture.threadID, title: "Fixture Chat", cwd: "/tmp/tether-fixture",
              updatedAt: 1_700_000_000_000, status: .idle)
    }

    func reply(method: String, params: JSONValue) -> Reply {
        switch method {
        case "initialize":
            return .init(value: .result(json(InitializeResult(
                serverInfo: .init(name: "tether-fixture", version: "1"),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "fixture-host", platform: "darwin", arch: "arm64",
                            home: "/tmp", pid: 1, mode: .daemon),
                claude: .init(path: "/fixture/claude", version: "fixture")
            ))))
        case "project/list":
            return .init(value: .result(json(ProjectListResult(projects: [
                .init(cwd: "/tmp/tether-fixture", lastActivity: 1_700_000_000_000, threadCount: 1)
            ]))))
        case "model/list": return .init(value: .result(json(ModelListResult(models: []))))
        case "thread/list":
            return .init(value: .result(json(ThreadListResult(threads: additionalThreads + [originalSummary]))))
        case "thread/read":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            let summary = additionalThreads.first { $0.threadId == id } ?? originalSummary
            let items: [Item] = id == UITestFixture.threadID ? [
                .userMessage(.init(id: "fixture-user", createdAt: 1_700_000_000_000,
                                   content: [.text(.init(text: "Summarize this project"))])),
                .agentMessage(.init(id: "fixture-answer", createdAt: 1_700_000_000_001,
                                    text: "Fixture answer from the local transport."))
            ] : []
            return .init(value: .result(json(ThreadReadResult(
                items: items, turns: [], summary: summary, historySeq: id == UITestFixture.threadID ? 1 : 0,
                hasMore: false
            ))))
        case "thread/subscribe":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            var reply = Reply(value: .result(json(ThreadSubscribeResult(
                thread: .init(threadId: id, status: .idle, cwd: "/tmp/tether-fixture", lastSeq: nextSequence),
                replayed: 0, gap: false
            ))))
            if id == UITestFixture.threadID, pendingPermission, !sentPermission {
                sentPermission = true
                let prompt = PermissionRequestParams(
                    threadId: id, requestId: "fixture-permission", toolUseId: "fixture-tool",
                    toolName: "Bash", input: ["command": "echo fixture"],
                    title: "Allow fixture command?", suppressAlwaysAllowRule: true
                )
                reply.requests = [(.number(900), "permission/request", json(prompt))]
            }
            return reply
        case "thread/unsubscribe": return .init(value: .result([:]))
        case "thread/start":
            let id = "fixture-new-\(additionalThreads.count + 1)"
            additionalThreads.insert(.init(threadId: id, title: "New Fixture Chat", cwd: "/tmp/tether-fixture",
                                           updatedAt: 1_700_000_000_002, status: .idle), at: 0)
            let info = ThreadInfo(threadId: id, status: .idle, cwd: "/tmp/tether-fixture", lastSeq: 0)
            return .init(value: .result(json(ThreadStartResult(thread: info))),
                         notifications: turnNotifications(threadID: id, input: params["input"]))
        case "turn/start":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            return .init(value: .result(json(TurnStartResult(turnId: "fixture-turn", messageId: "fixture-message", queued: false))),
                         notifications: turnNotifications(threadID: id, input: params["input"]))
        case "command/list": return .init(value: .result(["commands": []]))
        case "fs/search": return .init(value: .result(["paths": []]))
        default: return .init(value: .error("Unexpected fixture method: \(method)"))
        }
    }

    private func turnNotifications(threadID: String, input: JSONValue?) -> [(String, JSONValue)] {
        nextMessage += 1
        let text = input?.arrayValue?.first?["text"]?.stringValue ?? "Fixture input"
        let timestamp = 1_700_000_000_000.0 + Double(nextMessage * 10)
        let user = Item.userMessage(.init(id: "fixture-sent-\(nextMessage)", createdAt: timestamp,
                                          content: [.text(.init(text: text))]))
        let answerID = "fixture-stream-\(nextMessage)"
        let answer = Item.agentMessage(.init(id: answerID, createdAt: timestamp + 1, text: ""))
        let notifications: [(String, JSONValue)] = [
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 1, item: user))),
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 2, item: answer))),
            ("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: threadID, seq: nextSequence + 3, itemId: answerID, delta: "Scripted "))),
            ("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: threadID, seq: nextSequence + 4, itemId: answerID, delta: "response."))),
            ("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(nextSequence + 5)), "status": "idle"])
        ]
        nextSequence += 5
        return notifications
    }
}

private func json<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
#endif
