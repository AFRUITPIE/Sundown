#if DEBUG
import Foundation
import TetherProtocol

/// A process-free JSON-RPC server for XCTest UI runs. The only entry point is the explicit
/// TETHER_UI_TEST_MODE launch path; unhandled methods return an error instead of reaching Claude.
public enum UITestFixture {
    public static let threadID = "fixture-thread"

    @MainActor
    public static func connection(host: HostConfig = .local, failFirstConnect: Bool = false,
                                  pendingPermission: Bool = false, performance: Bool = false) -> HostConnection {
        let attempts = FixtureAttempts()
        return HostConnection(host: host, transportProvider: { _ in
            if failFirstConnect, await attempts.next() == 1 {
                throw TransportError.launchFailed("Fixture connection unavailable")
            }
            return FixtureTransport(pendingPermission: pendingPermission, performance: performance)
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

    init(pendingPermission: Bool, performance: Bool) {
        script = FixtureScript(pendingPermission: pendingPermission, performance: performance)
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
        if !reply.stream.isEmpty {
            // Paced like a real reply: a few characters per frame, after the transcript has settled.
            let continuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(2))
                for (name, params) in reply.stream {
                    let notification: JSONValue = ["method": .string(name), "params": params]
                    if let line = try? JSONEncoder().encode(notification) { continuation.yield(line) }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
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
        /// Sent one every 16 ms after the reply, for the performance scenario.
        var stream: [(String, JSONValue)] = []
    }

    private let pendingPermission: Bool
    private let performance: Bool
    private var streamed = false
    private var sentPermission = false
    private var nextSequence = 1
    private var nextMessage = 0
    private var additionalThreads: [ThreadSummary] = []

    init(pendingPermission: Bool, performance: Bool) {
        self.pendingPermission = pendingPermission
        self.performance = performance
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
            let perf = performance ? PerformanceTranscript.otherChats : []
            return .init(value: .result(json(ThreadListResult(threads: additionalThreads + perf + [originalSummary]))))
        case "thread/read":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            let summary = (additionalThreads + PerformanceTranscript.otherChats).first { $0.threadId == id } ?? originalSummary
            let items: [Item] = performance && (id == UITestFixture.threadID || id.hasPrefix("perf-chat-")) ? PerformanceTranscript.history : id == UITestFixture.threadID ? [
                .userMessage(.init(id: "fixture-user", createdAt: 1_700_000_000_000,
                                   content: [.text(.init(text: "Summarize this project"))])),
                .agentMessage(.init(id: "fixture-answer", createdAt: 1_700_000_000_001,
                                    text: "Fixture answer from the local transport."))
            ] : []
            // Paged from the end, as the server does.
            var page = items[...]
            if let before = params["before"]?.stringValue, let i = page.firstIndex(where: { $0.id == before }) {
                page = page[..<i]
            }
            let limit = params["limit"]?.intValue ?? page.count
            let shown = Array(page.suffix(limit))
            return .init(value: .result(json(ThreadReadResult(
                items: shown, turns: [], summary: summary, historySeq: id == UITestFixture.threadID || id.hasPrefix("perf-chat-") ? 1 : 0,
                hasMore: shown.count < page.count
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
            if id == UITestFixture.threadID, performance, !streamed {
                streamed = true
                reply.stream = PerformanceTranscript.reply(threadID: id, firstSeq: nextSequence + 1)
                nextSequence += reply.stream.count
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

/// A long transcript and a long streamed reply, for profiling (TETHER_UI_TEST_SCENARIO=performance).
/// Synthetic but shaped like real work: prompts, folded tool calls, and Markdown replies with
/// headings, lists, inline code, code blocks and tables.
enum PerformanceTranscript {
    /// Two more long chats, for switching between chats.
    static let otherChats: [ThreadSummary] = (1...2).map {
        .init(threadId: "perf-chat-\($0)", title: "Performance chat \($0)", cwd: "/tmp/tether-fixture",
              updatedAt: 1_700_000_000_000 - Double($0), status: .idle)
    }

    /// TETHER_PERF_TURNS sizes it (30 turns, 150 items, by default).
    static let history: [Item] = (0..<(Int(ProcessInfo.processInfo.environment["TETHER_PERF_TURNS"] ?? "") ?? 30)).flatMap { turn -> [Item] in
        let t = 1_700_000_000_000.0 + Double(turn * 100)
        var items: [Item] = [.userMessage(.init(id: "perf-user-\(turn)", createdAt: t,
                                                content: [.text(.init(text: "Step \(turn): look at the next part of the renderer and tighten it up."))]))]
        for call in 0..<3 {
            items.append(.toolCall(.init(id: "perf-tool-\(turn)-\(call)", createdAt: t + Double(call + 1), name: "Bash", kind: .bash,
                                         input: ["command": .string("rg -n 'MarkdownView' TetherKit/Sources | head -\(call + 5)")],
                                         status: .completed, outputText: "TetherKit/Sources/TetherUI/Markdown.swift:\(call + 5): struct MarkdownView: View {")))
        }
        items.append(.agentMessage(.init(id: "perf-answer-\(turn)", createdAt: t + 10, text: markdown(section: turn))))
        return items
    }

    /// About 10 KB of Markdown, streamed six characters at a time.
    static func reply(threadID: String, firstSeq: Int) -> [(String, JSONValue)] {
        let answerID = "perf-streaming-answer"
        var seq = firstSeq
        var out: [(String, JSONValue)] = [
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: seq, item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_000_000, text: ""))))),
        ]
        let text = (0..<6).map { markdown(section: 100 + $0) }.joined(separator: "\n\n")
        var rest = Substring(text)
        while !rest.isEmpty {
            seq += 1
            let chunk = rest.prefix(6)
            rest = rest.dropFirst(6)
            out.append(("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: threadID, seq: seq, itemId: answerID, delta: String(chunk)))))
        }
        return out
    }

    static func markdown(section n: Int) -> String {
        """
        ## Section \(n): tightening the renderer

        The transcript re-renders on every streamed token, so anything **proportional to its length** \
        shows up as dropped frames. Here the cost is in `MarkdownCache.blocks(for:)` and in the rows \
        that `TranscriptView` diffs — each one cheap alone, but multiplied by every token.

        - Parse only the tail that changed; the settled prefix stays as it was.
        - Keep each finished block's view equal to its last, so SwiftUI skips it.
        - Measure with signposts before and after — a guess isn't a result.

        ```swift
        func blocks(for text: String) -> [Block] {
            if text == last { return cached }
            let tail = text.dropFirst(settled.utf8.count)
            return settledBlocks + parse(tail)
        }
        ```

        | Step | Before | After |
        |------|--------|-------|
        | Parse | \(n % 7 + 3) ms | 0.\(n % 9) ms |
        | Rows | \(n % 5 + 2) ms | 0.1 ms |

        > Streaming should cost what the new characters cost, not what the whole message costs.
        """
    }
}

private func json<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
#endif
