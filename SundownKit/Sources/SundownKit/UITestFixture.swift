import Foundation
import TetherProtocol

/// A process-free JSON-RPC server for XCTest UI runs. In every build, inert unless the app is
/// launched with SUNDOWN_UI_TEST_MODE=1: the performance tests run against a Release build. The only entry point is the explicit
/// SUNDOWN_UI_TEST_MODE launch path; unhandled methods return an error instead of reaching Claude.
public enum UITestFixture {
    public static let threadID = "fixture-thread"

    /// `failedConnects` attempts fail before one succeeds: two keep the status card up for a few
    /// seconds of retries, long enough to press its Reconnect.
    ///
    /// Two more knobs, read here: the `prompts` scenario (this Mac's host only) asks for a
    /// permission, another, a question, a form and a very long question in turn, each once the one
    /// before is answered, and puts each answer in the chat as a reply; `SUNDOWN_UI_TEST_FAIL=a,b`
    /// answers those methods with an error ("Fixture a failed").
    @MainActor
    public static func connection(host: HostConfig = .local, failedConnects: Int = 0,
                                  pendingPermission: Bool = false, performance: Bool = false) -> HostConnection {
        let attempts = FixtureAttempts()
        let environment = ProcessInfo.processInfo.environment
        let prompts = host.id == HostConfig.local.id && environment["SUNDOWN_UI_TEST_SCENARIO"] == "prompts"
        let tasks = environment["SUNDOWN_UI_TEST_SCENARIO"] == "tasks"
        let failing = Set((environment["SUNDOWN_UI_TEST_FAIL"] ?? "").split(separator: ",").map(String.init))
        // SUNDOWN_UI_TEST_GAP=1: every connection after the first is a daemon that lost the stream, so
        // resubscribing reports a replay gap and the chat reloads (sleep, a daemon restart).
        let gaps = environment["SUNDOWN_UI_TEST_GAP"] == "1"
        return HostConnection(host: host, transportProvider: { _ in
            let attempt = await attempts.next()
            if attempt <= failedConnects {
                throw TransportError.launchFailed("Fixture connection unavailable")
            }
            return FixtureTransport(pendingPermission: pendingPermission || prompts, performance: performance,
                                    prompts: prompts, tasks: tasks, failing: failing,
                                    reportsGap: gaps && attempt > failedConnects + 1)
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

    init(pendingPermission: Bool, performance: Bool, prompts: Bool = false, tasks: Bool = false, failing: Set<String> = [],
         reportsGap: Bool = false) {
        script = FixtureScript(pendingPermission: pendingPermission, performance: performance, prompts: prompts,
                               tasks: tasks, failing: failing, reportsGap: reportsGap)
        var captured: AsyncThrowingStream<Data, any Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = request["id"] else { return }
        guard let method = request["method"]?.stringValue else {
            // The app's answer to one of the fixture's requests.
            for message in await script.answered(id: id, result: request["result"] ?? request["error"] ?? .null) {
                continuation.yield(try JSONEncoder().encode(message))
            }
            return
        }
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
    /// The `prompts` scenario: each answered request brings the next (`answered`).
    private let prompts: Bool
    /// The `tasks` scenario: the chat has started one of each kind of task (`TaskTranscript`).
    private let tasks: Bool
    /// Methods answered with an error (SUNDOWN_UI_TEST_FAIL).
    private let failing: Set<String>
    /// A resubscription after events were seen reports a replay gap (SUNDOWN_UI_TEST_GAP).
    private let reportsGap: Bool
    private var sentPermission = false
    private var nextSequence = 1
    private var nextMessage = 0
    private var additionalThreads: [ThreadSummary] = []
    /// Rename, Duplicate and Delete, as the list and reads then show them.
    private var titles: [String: String] = [:]
    private var deleted: Set<String> = []
    private var tags: [String: String] = [:]
    /// A fork's id, and the chat whose items it reads.
    private var forks: [String: String] = [:]
    /// How many times Restore Code has run.
    private var rewound = 0

    init(pendingPermission: Bool, performance: Bool, prompts: Bool = false, tasks: Bool = false, failing: Set<String> = [],
         reportsGap: Bool = false) {
        self.reportsGap = reportsGap
        self.pendingPermission = pendingPermission
        self.performance = performance
        self.prompts = prompts
        self.tasks = tasks
        self.failing = failing
    }

    private var originalSummary: ThreadSummary {
        .init(threadId: UITestFixture.threadID, title: "Fixture Chat", cwd: "/tmp/sundown-fixture",
              updatedAt: 1_700_000_000_000, status: .idle)
    }

    func reply(method: String, params: JSONValue) -> Reply {
        if failing.contains(method) { return .init(value: .error("Fixture \(method) failed")) }
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
                .init(cwd: "/tmp/sundown-fixture", lastActivity: 1_700_000_000_000, threadCount: 1)
            ]))))
        case "model/list": return .init(value: .result(json(ModelListResult(models: []))))
        // As a host whose Claude Code would start in auto mode at medium effort.
        case "session/defaults":
            return .init(value: .result(json(SessionDefaultsResult(model: "sonnet", effort: .medium, permissionMode: .auto))))
        case "thread/list":
            let perf = performance ? PerformanceTranscript.otherChats : []
            let threads = (additionalThreads + perf + [originalSummary])
                .filter { !deleted.contains($0.threadId) }
                .map { summary in
                    var summary = summary
                    if let title = titles[summary.threadId] { summary.customTitle = title }
                    if let tag = tags[summary.threadId] { summary.tag = tag }
                    return summary
                }
            return .init(value: .result(json(ThreadListResult(threads: threads))))
        case "thread/tag":
            if let id = params["threadId"]?.stringValue { tags[id] = params["tag"]?.stringValue }
            return .init(value: .result([:]))
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
            additionalThreads.insert(.init(threadId: id, title: title, cwd: "/tmp/sundown-fixture",
                                           updatedAt: 1_700_000_000_003, status: .idle), at: 0)
            return .init(value: .result(json(ThreadForkResult(threadId: id))))
        case "thread/read":
            let requested = params["threadId"]?.stringValue ?? UITestFixture.threadID
            // A fork reads as the chat it was made from.
            let id = forks[requested] ?? requested
            var summary = (additionalThreads + PerformanceTranscript.otherChats).first { $0.threadId == requested } ?? originalSummary
            if let title = titles[requested] { summary.customTitle = title }
            let items: [Item] = tasks && id == UITestFixture.threadID ? TaskTranscript.items()
                : performance && (id == UITestFixture.threadID || id.hasPrefix("perf-chat-")) ? PerformanceTranscript.history : id == UITestFixture.threadID ? [
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
            // The performance scenario's other chats aren't live in the daemon, as most of a real
            // host's aren't: they're followed, let go when left, and read again when reopened.
            let status: ThreadStatus = id.hasPrefix("perf-chat-") ? .notLoaded : .idle
            var reply = Reply(value: .result(json(ThreadSubscribeResult(
                thread: .init(threadId: id, status: status, cwd: "/tmp/sundown-fixture", lastSeq: nextSequence),
                replayed: 0, gap: reportsGap && (params["afterSeq"]?.intValue ?? 0) > 1
            ))))
            if id == UITestFixture.threadID, tasks {
                reply.notifications = TaskTranscript.events(threadID: id, firstSeq: nextSequence + 1)
                nextSequence += reply.notifications.count
            }
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
            additionalThreads.insert(.init(threadId: id, title: "New Fixture Chat", cwd: "/tmp/sundown-fixture",
                                           updatedAt: 1_700_000_000_002, status: .idle), at: 0)
            let mode = params["permissionMode"]?.stringValue.flatMap(PermissionMode.init(rawValue:)) ?? .auto
            let info = ThreadInfo(threadId: id, status: .idle, cwd: "/tmp/sundown-fixture", appliedEffort: .medium,
                                  permissionMode: mode, lastSeq: 0)
            return .init(value: .result(json(ThreadStartResult(thread: info))),
                         notifications: turnNotifications(threadID: id, input: params["input"]))
        case "turn/start":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            if performance { return performanceTurn(threadID: id, input: params["input"]) }
            let notifications = turnNotifications(threadID: id, input: params["input"])
            return .init(value: .result(json(TurnStartResult(turnId: "fixture-turn", messageId: "fixture-sent-\(nextMessage)", queued: false))),
                         notifications: notifications)
        case "thread/sideQuestion":
            let q = params["question"]?.stringValue ?? ""
            return .init(value: .result(["answer": .string("A side answer to “\(q)”.")]))
        case "git/status":
            return .init(value: .result(["isRepo": true, "branch": "main", "files": [["status": "M", "path": "Sources/App.swift"]]]))
        case "git/diff":
            let staged = params["staged"]?.boolValue ?? false
            return .init(value: .result(["diff": .string(staged ? "" : """
            diff --git a/Sources/App.swift b/Sources/App.swift
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,3 +1,3 @@
             import SwiftUI
            -let greeting = "Hello"
            +let greeting = "Hello, Sundown"
             print(greeting)
            """)]))
        case "thread/rewindFiles":
            let dryRun = params["dryRun"]?.boolValue ?? false
            rewound += dryRun ? 0 : 1
            // Once put back, there's nothing left to restore.
            let changed: JSONValue = rewound > 0 && dryRun ? [] : ["/tmp/sundown-fixture/Sources/App.swift", "/tmp/sundown-fixture/README.md"]
            return .init(value: .result(["result": ["canRewind": true, "filesChanged": changed, "insertions": 12, "deletions": 3]]))
        case "command/list":
            return .init(value: .result(["commands": [
                ["name": "compact", "description": "Compact the conversation"],
                ["name": "context", "description": "Show context usage"],
                ["name": "review", "description": "Review the current changes"],
                ["name": "help", "description": "Show available commands"],
                ["name": "status", "description": "Show session status"]
            ]]))
        case "fs/search": return .init(value: .result(["paths": []]))
        case "workflow/read":
            guard params["runId"]?.stringValue == WorkflowSample.runID else { return .init(value: .result(["workflow": .null])) }
            return .init(value: .result(["workflow": WorkflowSample.snapshot(now: TaskTranscript.workflowNow, running: false)]))
        case "workflow/agentItems":
            let agent = params["agentId"]?.stringValue ?? ""
            return .init(value: .result(["items": json(WorkflowSample.agentItems(agentId: agent, now: TaskTranscript.workflowNow))]))
        default: return .init(value: .error("Unexpected fixture method: \(method)"))
        }
    }

    // MARK: The prompts scenario

    /// The app's answer to request `id`, said in the chat as a reply ("Answered: " and the answer's
    /// JSON, keys sorted), and the request that comes after it: the permission asked on subscribe
    /// (900), a second permission, a question, a form, then a question too long for the window.
    func answered(id: JSONValue, result: JSONValue) -> [JSONValue] {
        guard prompts, let answered = id.intValue else { return [] }
        let thread = UITestFixture.threadID
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = (try? encoder.encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        let item = Item.agentMessage(.init(id: "fixture-answered-\(answered)", createdAt: 1_700_000_000_100 + Double(answered),
                                           text: "Answered: \(text)"))
        var out: [JSONValue] = [
            ["method": "item/started", "params": json(ItemStartedNotification(threadId: thread, seq: nextSequence + 1, item: item))],
            ["method": "item/completed", "params": json(ItemCompletedNotification(threadId: thread, seq: nextSequence + 2, item: item))],
        ]
        nextSequence += 2
        let next: (method: String, params: JSONValue)? = switch answered {
        case 900: ("permission/request", json(PermissionRequestParams(
            threadId: thread, requestId: "fixture-second-permission", toolUseId: "fixture-second-tool", toolName: "Bash",
            input: ["command": "echo second"], title: "Allow second command?", suppressAlwaysAllowRule: true)))
        case 901: ("question/request", question(threadID: thread, long: false))
        case 902: ("elicitation/request", json(ElicitationRequestParams(
            threadId: thread, requestId: "fixture-elicitation", serverName: "Fixture Server",
            message: "Tell the server about the project.", requestedSchema: [
                "type": "object",
                "properties": ["name": ["type": "string", "title": "Project Name", "description": "What to call it"]],
                "required": ["name"],
            ])))
        case 903: ("question/request", question(threadID: thread, long: true))
        default: nil
        }
        if let next {
            out.append(["id": .number(Double(answered + 1)), "method": .string(next.method), "params": next.params])
        }
        return out
    }

    /// One question with three choices, or one so long, with thirty long choices, that the card
    /// is taller than the window.
    private func question(threadID: String, long: Bool) -> JSONValue {
        let filler = long ? String(repeating: "This sentence makes the question much longer than a card expects. ", count: 60) : ""
        let options: [QuestionRequestParams.Question.Option] = long
            ? (1...30).map { .init(label: "Option number \($0) with a rather long label that goes on",
                                   description: String(repeating: "Describes option \($0) at length. ", count: 6)) }
            : [.init(label: "Postgres", description: "A server"), .init(label: "SQLite", description: "A file"),
               .init(label: "MySQL", description: "Another server")]
        return json(QuestionRequestParams(threadId: threadID, requestId: long ? "fixture-long-question" : "fixture-question",
                                          toolUseId: long ? "fixture-long-question-tool" : "fixture-question-tool", questions: [
            .init(question: "Which database should we use? " + filler, header: "Database", multiSelect: false, options: options)
        ]))
    }

    /// A prompt in the performance scenario gets a long working reply: the turn, the prompt and
    /// "running" at once, then tool calls and Markdown streamed a few characters a frame, then the
    /// turn's end and "idle", in the order a real host sends them.
    private func performanceTurn(threadID: String, input: JSONValue?) -> Reply {
        nextMessage += 1
        let turn = nextMessage
        let text = input?.arrayValue?.first?["text"]?.stringValue ?? "Fixture input"
        let user = Item.userMessage(.init(id: "perf-sent-\(turn)", createdAt: 1_900_000_000_000 + Double(turn * 1000),
                                          content: [.text(.init(text: text))]))
        var reply = Reply(value: .result(json(TurnStartResult(turnId: "perf-turn-\(turn)", messageId: "perf-sent-\(turn)", queued: false))))
        let started = Turn(id: "perf-turn-\(turn)", status: .inProgress, startedAt: 1_900_000_000_000 + Double(turn * 1000))
        var completed = started
        completed.status = .completed
        reply.notifications = [
            ("turn/started", json(TurnStartedNotification(threadId: threadID, seq: nextSequence + 1, turn: started))),
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 2, item: user))),
            ("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(nextSequence + 3)), "status": "running"]),
        ]
        reply.stream = PerformanceTranscript.reply(threadID: threadID, firstSeq: nextSequence + 4, turn: turn)
        let last = nextSequence + 4 + reply.stream.count
        reply.stream.append(("turn/completed", json(TurnCompletedNotification(threadId: threadID, seq: last, turn: completed))))
        reply.stream.append(("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(last + 1)), "status": "idle"]))
        nextSequence = last + 1
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
        var notifications: [(String, JSONValue)] = [
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 1, item: user))),
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 2, item: answer))),
            ("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: threadID, seq: nextSequence + 3, itemId: answerID, delta: "Scripted "))),
            ("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: threadID, seq: nextSequence + 4, itemId: answerID, delta: "response."))),
            ("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(nextSequence + 5)), "status": "idle"])
        ]
        nextSequence += 5
        // As session tools' suggest_task would.
        if text.localizedCaseInsensitiveContains("suggest a task") {
            nextSequence += 1
            notifications.append(("thread/taskSuggested", ["threadId": .string(threadID), "seq": .number(Double(nextSequence)),
                                                           "title": "Write the release notes", "prompt": "Draft release notes for 0.6."]))
        }
        return notifications
    }
}

/// A long transcript and a long streamed reply, for profiling (SUNDOWN_UI_TEST_SCENARIO=performance).
/// Synthetic but shaped like real work: prompts, folded tool calls, and Markdown replies with
/// headings, lists, inline code, code blocks and tables.
enum PerformanceTranscript {
    /// Two more long chats, for switching between chats.
    static let otherChats: [ThreadSummary] = (1...2).map {
        .init(threadId: "perf-chat-\($0)", title: "Performance chat \($0)", cwd: "/tmp/sundown-fixture",
              updatedAt: 1_700_000_000_000 - Double($0), status: .idle)
    }

    /// SUNDOWN_PERF_TURNS sizes it (30 turns by default). Each turn works the way a real one does:
    /// bursts of tool calls with a line of text between them, now and then a failed call, which stays
    /// on its own row, and a Markdown answer at the end.
    static let history: [Item] = (0..<(Int(ProcessInfo.processInfo.environment["SUNDOWN_PERF_TURNS"] ?? "") ?? 30)).flatMap { turn -> [Item] in
        let t = 1_700_000_000_000.0 + Double(turn * 1000)
        var items: [Item] = [.userMessage(.init(id: "perf-user-\(turn)", createdAt: t,
                                                content: [.text(.init(text: "Step \(turn): look at the next part of the renderer and tighten it up."))]))]
        var n = 0
        // A long current turn exposes eager layout work that the usual small turns conceal.
        let bursts = turn == 29 && ProcessInfo.processInfo.environment["SUNDOWN_PERF_LONG_TURN"] == "1" ? 80 : 3
        for burst in 0..<bursts {
            for _ in 0..<(2 + (turn + burst * 3) % 7) {
                let status: ToolStatus = turn % 4 == 1 && burst == 1 && n % 5 == 2 ? .failed : .completed
                items.append(toolCall(id: "perf-tool-\(turn)-\(n)", at: t + Double(n + 1), index: turn + n, status: status))
                n += 1
            }
            if burst < bursts - 1 {
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
        let file = "SundownKit/Sources/SundownUI/\(files[i % files.count])"
        let failed = status == .failed
        switch i % 5 {
        case 0:
            return .toolCall(.init(id: id, createdAt: time, name: "Bash", kind: .bash,
                                   input: ["command": .string("rg -n 'MarkdownView' SundownKit/Sources | head -\(i % 9 + 3)")],
                                   status: status, outputText: failed ? "rg: SundownKit/Sources/Missing: No such file or directory" : "\(file):\(i % 90 + 5): struct MarkdownView: View {",
                                   isError: failed ? true : nil))
        case 1:
            return .toolCall(.init(id: id, createdAt: time, name: "Read", kind: .fileRead, input: ["file_path": .string(file)],
                                   status: status, outputText: (0..<12).map { "\($0 + 1)\timport SwiftUI // line \($0)" }.joined(separator: "\n")))
        case 2:
            return .toolCall(.init(id: id, createdAt: time, name: "Grep", kind: .grep,
                                   input: ["pattern": .string("readingColumn"), "path": .string("SundownKit/Sources")],
                                   status: status, outputText: files.map { "SundownKit/Sources/SundownUI/\($0)" }.joined(separator: "\n")))
        case 3:
            return .toolCall(.init(id: id, createdAt: time, name: "Edit", kind: .fileEdit,
                                   input: ["file_path": .string(file), "old_string": .string("let blocks = parse(text)"),
                                           "new_string": .string("let blocks = cache.blocks(for: text)")],
                                   status: status, outputText: failed ? "String to replace not found in file." : "The file \(file) has been updated.",
                                   isError: failed ? true : nil))
        default:
            return .toolCall(.init(id: id, createdAt: time, name: "Glob", kind: .glob, input: ["pattern": .string("**/*View.swift")],
                                   status: status, outputText: files.map { "SundownKit/Sources/SundownUI/\($0)" }.joined(separator: "\n")))
        }
    }

    /// SUNDOWN_PERF_REPLY_SECTIONS sections (3 by default, about 3 KB and 10 s) of Markdown streamed
    /// six characters a frame, each after a burst of tool calls that start running and complete a
    /// few frames later, as a real turn's do. `turn` keeps each reply's items distinct.
    static let replySections = Int(ProcessInfo.processInfo.environment["SUNDOWN_PERF_REPLY_SECTIONS"] ?? "") ?? 3

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
        // SUNDOWN_PERF_LONG_REPLY=n: then one reply of n sections, as a long report is: a single
        // message thousands of points tall. Streamed faster, 60 characters a frame.
        if longReplySections > 0 {
            let answerID = "perf-\(turn)-long"
            let text = (0..<longReplySections).map { markdown(section: 200 + $0) }.joined(separator: "\n\n")
            out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_090_000, text: ""))))))
            var rest = Substring(text)
            while !rest.isEmpty {
                let chunk = rest.prefix(60)
                rest = rest.dropFirst(60)
                out.append(("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                    threadId: threadID, seq: next(), itemId: answerID, delta: String(chunk)))))
            }
            out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_090_000, text: text))))))
        }
        return out
    }

    static let longReplySections = Int(ProcessInfo.processInfo.environment["SUNDOWN_PERF_LONG_REPLY"] ?? "") ?? 0

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

/// The `tasks` scenario's chat: a workflow that has finished (`WorkflowSample`, its result a
/// message of its own before the next prompt), then an agent that started an agent and a
/// background command, a monitor and an MCP tool, as the SDK reports them, running and finished.
private enum TaskTranscript {
    /// When the workflow ran: before the rest of the chat.
    static var workflowNow: Double { Date().timeIntervalSince1970 * 1000 - 500_000 }

    static func items() -> [Item] {
        let now = Date().timeIntervalSince1970 * 1000
        func ago(_ seconds: Double) -> Double { now - seconds * 1000 }
        func call(_ id: String, _ name: String, _ kind: ToolKind, _ input: JSONValue, status: ToolStatus = .completed,
                  output: String? = nil, parent: String? = nil, at seconds: Double) -> Item {
            .toolCall(.init(id: id, parentToolUseId: parent, createdAt: ago(seconds), name: name, kind: kind, input: input,
                            status: status, outputText: output))
        }
        let root = "/tmp/sundown-fixture/Sources/"
        return WorkflowSample.items(now: workflowNow, running: false) + [
            .userMessage(.init(id: "tasks-user", createdAt: ago(400),
                               content: [.text(.init(text: "Review the changes, and find which views read thread.items."))])),
            call("agent-1", "Task", .subagent, [
                "subagent_type": "Explore", "description": "Find every SwiftUI view",
                "prompt": "Find every SwiftUI view and list which read `thread.items`.",
            ], status: .running, at: 100),
            call("agent-1-grep", "Grep", .grep, ["pattern": "thread\\.items", "path": .string(root)],
                 output: "TranscriptFind.swift:88\nThreadView.swift:41", parent: "agent-1", at: 95),
            .agentMessage(.init(id: "agent-1-reply", parentToolUseId: "agent-1", createdAt: ago(80),
                                text: "Most views read `rows`, not `items`. Two exceptions so far:\n\n- `TranscriptFind` builds its search text from items.\n- `ThreadView` reads the last item.")),
            call("bg-call", "Bash", .bash, [
                "command": "swift test", "description": "Run the tests", "run_in_background": true,
            ], output: "Command running in background", parent: "agent-1", at: 70),
            call("agent-2", "Task", .subagent, [
                "description": "Check how TranscriptFind reads items",
                "prompt": "Read TranscriptFind.swift and say how it builds its search text.",
            ], status: .running, parent: "agent-1", at: 34),
            call("agent-2-read", "Read", .fileRead, ["file_path": .string(root + "TranscriptFind.swift")],
                 status: .running, parent: "agent-2", at: 5),
            call("failed-call", "Bash", .bash, ["command": "xcodebuild -scheme Sundown build", "run_in_background": true],
                 output: "** BUILD FAILED **", at: 300),
        ]
    }

    static func events(threadID: String, firstSeq: Int) -> [(String, JSONValue)] {
        var seq = firstSeq
        func event(_ name: String, _ id: String, _ type: String, _ description: String, toolUseId: String? = nil,
                   status: String, summary: String? = nil, extra: [String: JSONValue] = [:]) -> (String, JSONValue) {
            var data: [String: JSONValue] = ["task_type": .string(type)]
            for (k, v) in extra { data[k] = v }
            defer { seq += 1 }
            return ("task/event", json(TaskEventNotification(threadId: threadID, seq: seq, event: name, taskId: id, toolUseId: toolUseId,
                                                             description: description, status: status, summary: summary,
                                                             data: .object(data))))
        }
        let workflow = WorkflowSample.events(threadID: threadID, firstSeq: seq, now: workflowNow, running: false)
            .map { ("task/event", json($0)) }
        seq += workflow.count
        return workflow + [
            event("started", "agent-task-1", "local_agent", "Find every SwiftUI view", toolUseId: "agent-1", status: "running"),
            event("started", "bg-tests", "local_bash", "swift test", toolUseId: "bg-call", status: "running"),
            event("started", "agent-task-2", "local_agent", "Check how TranscriptFind reads items", toolUseId: "agent-2",
                  status: "running"),
            event("started", "monitor-1", "monitor", "Watch CI on the pull request", status: "running"),
            event("notification", "mcp-1", "mcp_task", "Run all tests in Xcode", status: "completed",
                  summary: "412 tests passed, 3 skipped.", extra: ["usage": ["duration_ms": 243_000, "total_tokens": 0, "tool_uses": 1]]),
            event("notification", "build-1", "local_bash", "xcodebuild -scheme Sundown build", toolUseId: "failed-call",
                  status: "failed", summary: "Build failed", extra: ["usage": ["duration_ms": 123_000, "total_tokens": 0, "tool_uses": 0]]),
        ]
    }
}

private func json<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
