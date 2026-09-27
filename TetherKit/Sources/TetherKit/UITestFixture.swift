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
            // Paced like a real reply: a few characters per frame, after a moment's thought.
            let continuation = continuation
            Task {
                try? await Task.sleep(for: .milliseconds(300))
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
    private var sentPermission = false
    private var nextSequence = 1
    private var nextMessage = 0
    private var additionalThreads: [ThreadSummary] = []
    /// Rename, Duplicate and Delete, as the list and reads then show them.
    private var titles: [String: String] = [:]
    private var deleted: Set<String> = []
    /// A fork's id, and the chat whose items it reads.
    private var forks: [String: String] = [:]

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
            let threads = (additionalThreads + perf + [originalSummary])
                .filter { !deleted.contains($0.threadId) }
                .map { summary in
                    var summary = summary
                    if let title = titles[summary.threadId] { summary.customTitle = title }
                    return summary
                }
            return .init(value: .result(json(ThreadListResult(threads: threads))))
        case "thread/rename":
            if let id = params["threadId"]?.stringValue, let title = params["title"]?.stringValue { titles[id] = title }
            return .init(value: .result([:]))
        case "thread/delete":
            if let id = params["threadId"]?.stringValue { deleted.insert(id) }
            return .init(value: .result([:]))
        case "thread/fork":
            let source = params["threadId"]?.stringValue ?? UITestFixture.threadID
            let id = "fixture-fork-\(forks.count + 1)"
            forks[id] = forks[source] ?? source
            let title = (additionalThreads + PerformanceTranscript.otherChats + [originalSummary])
                .first { $0.threadId == source }.map { titles[source] ?? $0.title } ?? "Chat"
            additionalThreads.insert(.init(threadId: id, title: title, cwd: "/tmp/tether-fixture",
                                           updatedAt: 1_700_000_000_003, status: .idle), at: 0)
            return .init(value: .result(json(ThreadForkResult(threadId: id))))
        case "thread/read":
            let requested = params["threadId"]?.stringValue ?? UITestFixture.threadID
            // A fork reads as the chat it was made from.
            let id = forks[requested] ?? requested
            var summary = (additionalThreads + PerformanceTranscript.otherChats).first { $0.threadId == requested } ?? originalSummary
            if let title = titles[requested] { summary.customTitle = title }
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
            if performance { return performanceTurn(threadID: id, input: params["input"]) }
            return .init(value: .result(json(TurnStartResult(turnId: "fixture-turn", messageId: "fixture-message", queued: false))),
                         notifications: turnNotifications(threadID: id, input: params["input"]))
        case "command/list": return .init(value: .result(["commands": []]))
        case "fs/search": return .init(value: .result(["paths": []]))
        default: return .init(value: .error("Unexpected fixture method: \(method)"))
        }
    }

    /// A prompt in the performance scenario gets a long working reply: the prompt and "running" at
    /// once, then tool calls and Markdown streamed a few characters a frame, then "idle".
    private func performanceTurn(threadID: String, input: JSONValue?) -> Reply {
        nextMessage += 1
        let turn = nextMessage
        let text = input?.arrayValue?.first?["text"]?.stringValue ?? "Fixture input"
        let user = Item.userMessage(.init(id: "perf-sent-\(turn)", createdAt: 1_900_000_000_000 + Double(turn * 1000),
                                          content: [.text(.init(text: text))]))
        var reply = Reply(value: .result(json(TurnStartResult(turnId: "perf-turn-\(turn)", messageId: "perf-message-\(turn)", queued: false))))
        reply.notifications = [
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 1, item: user))),
            ("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(nextSequence + 2)), "status": "running"]),
        ]
        reply.stream = PerformanceTranscript.reply(threadID: threadID, firstSeq: nextSequence + 3, turn: turn)
        let last = nextSequence + 3 + reply.stream.count
        reply.stream.append(("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(last)), "status": "idle"]))
        nextSequence = last
        return reply
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

    /// TETHER_PERF_TURNS sizes it (30 turns by default). Each turn works the way a real one does:
    /// bursts of tool calls with a line of text between them, now and then a failed call, which stays
    /// on its own row, and a Markdown answer at the end.
    static let history: [Item] = (0..<(Int(ProcessInfo.processInfo.environment["TETHER_PERF_TURNS"] ?? "") ?? 30)).flatMap { turn -> [Item] in
        let t = 1_700_000_000_000.0 + Double(turn * 1000)
        var items: [Item] = [.userMessage(.init(id: "perf-user-\(turn)", createdAt: t,
                                                content: [.text(.init(text: "Step \(turn): look at the next part of the renderer and tighten it up."))]))]
        var n = 0
        for burst in 0..<3 {
            for _ in 0..<(2 + (turn + burst * 3) % 7) {
                let status: ToolStatus = turn % 4 == 1 && burst == 1 && n % 5 == 2 ? .failed : .completed
                items.append(toolCall(id: "perf-tool-\(turn)-\(n)", at: t + Double(n + 1), index: turn + n, status: status))
                n += 1
            }
            if burst < 2 {
                items.append(.agentMessage(.init(id: "perf-note-\(turn)-\(burst)", createdAt: t + Double(n + 1),
                                                 text: "Found it in `\(files[(turn + burst) % files.count])`. Checking the callers next.")))
            }
        }
        items.append(.agentMessage(.init(id: "perf-answer-\(turn)", createdAt: t + 500, text: markdown(section: turn))))
        return items
    }

    private static let files = ["Markdown.swift", "TranscriptView.swift", "ThreadModel.swift", "ItemViews.swift", "ToolCallView.swift"]

    /// One of the tools a turn uses most, with the input and output each is shown with.
    static func toolCall(id: String, at time: Double, index i: Int, status: ToolStatus) -> Item {
        let file = "TetherKit/Sources/TetherUI/\(files[i % files.count])"
        let failed = status == .failed
        switch i % 5 {
        case 0:
            return .toolCall(.init(id: id, createdAt: time, name: "Bash", kind: .bash,
                                   input: ["command": .string("rg -n 'MarkdownView' TetherKit/Sources | head -\(i % 9 + 3)")],
                                   status: status, outputText: failed ? "rg: TetherKit/Sources/Missing: No such file or directory" : "\(file):\(i % 90 + 5): struct MarkdownView: View {",
                                   isError: failed ? true : nil))
        case 1:
            return .toolCall(.init(id: id, createdAt: time, name: "Read", kind: .fileRead, input: ["file_path": .string(file)],
                                   status: status, outputText: (0..<12).map { "\($0 + 1)\timport SwiftUI // line \($0)" }.joined(separator: "\n")))
        case 2:
            return .toolCall(.init(id: id, createdAt: time, name: "Grep", kind: .grep,
                                   input: ["pattern": .string("readingColumn"), "path": .string("TetherKit/Sources")],
                                   status: status, outputText: files.map { "TetherKit/Sources/TetherUI/\($0)" }.joined(separator: "\n")))
        case 3:
            return .toolCall(.init(id: id, createdAt: time, name: "Edit", kind: .fileEdit,
                                   input: ["file_path": .string(file), "old_string": .string("let blocks = parse(text)"),
                                           "new_string": .string("let blocks = cache.blocks(for: text)")],
                                   status: status, outputText: failed ? "String to replace not found in file." : "The file \(file) has been updated.",
                                   isError: failed ? true : nil))
        default:
            return .toolCall(.init(id: id, createdAt: time, name: "Glob", kind: .glob, input: ["pattern": .string("**/*View.swift")],
                                   status: status, outputText: files.map { "TetherKit/Sources/TetherUI/\($0)" }.joined(separator: "\n")))
        }
    }

    /// TETHER_PERF_REPLY_SECTIONS sections (3 by default, about 3 KB and 10 s) of Markdown streamed
    /// six characters a frame, each after a burst of tool calls that start running and complete a
    /// few frames later, as a real turn's do. `turn` keeps each reply's items distinct.
    static let replySections = Int(ProcessInfo.processInfo.environment["TETHER_PERF_REPLY_SECTIONS"] ?? "") ?? 3

    static func reply(threadID: String, firstSeq: Int, turn: Int) -> [(String, JSONValue)] {
        var seq = firstSeq
        var out: [(String, JSONValue)] = []
        func next() -> Int { seq += 1; return seq - 1 }
        for section in 0..<replySections {
            for call in 0..<(3 + section % 4) {
                let id = "perf-\(turn)-tool-\(section)-\(call)", time = 1_800_000_000_000.0 + Double(section * 100 + call)
                let done = toolCall(id: id, at: time, index: section * 7 + call, status: .completed)
                guard case .toolCall(var running) = done else { continue }
                running.status = .running
                running.outputText = nil
                out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item: .toolCall(running)))))
                // Blank frames: the call runs for a moment before it completes. The first runs for
                // a few seconds, long enough for a UI test to find it running.
                for _ in 0..<(section == 0 && call == 0 ? 200 : 4) { out.append(("item/toolCall/progress", json(ItemToolCallProgressNotification(
                    threadId: threadID, seq: next(), itemId: id, elapsedSeconds: 0.1)))) }
                out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item: done))))
            }
            let answerID = "perf-\(turn)-answer-\(section)"
            out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_000_000 + Double(section * 100 + 50), text: ""))))))
            var rest = Substring(markdown(section: 100 + section))
            while !rest.isEmpty {
                let chunk = rest.prefix(6)
                rest = rest.dropFirst(6)
                out.append(("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                    threadId: threadID, seq: next(), itemId: answerID, delta: String(chunk)))))
            }
            out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_000_000 + Double(section * 100 + 50),
                                    text: markdown(section: 100 + section)))))))
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
