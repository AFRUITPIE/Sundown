import Foundation
import TetherProtocol

/// A process-free JSON-RPC server for XCTest UI runs. In every build, inert unless the app is
/// launched with SUNDOWN_UI_TEST_MODE=1: the performance tests run against a Release build. The only entry point is the explicit
/// SUNDOWN_UI_TEST_MODE launch path; unhandled methods return an error instead of reaching Claude.
public enum UITestFixture {
    public static let threadID = "fixture-thread"
    /// The chat the `showcase` scenario opens on.
    public static let showcaseThreadID = ShowcaseTranscript.mainThreadID

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
        let scenario = environment["SUNDOWN_UI_TEST_SCENARIO"]
        let prompts = host.id == HostConfig.local.id && scenario == "prompts"
        let options = FixtureOptions(
            pendingPermission: pendingPermission || prompts, performance: performance, prompts: prompts,
            tasks: scenario == "tasks", showcase: scenario == "showcase",
            failing: Set((environment["SUNDOWN_UI_TEST_FAIL"] ?? "").split(separator: ",").map(String.init)))
        // SUNDOWN_UI_TEST_GAP=1: every connection after the first is a daemon that lost the stream, so
        // resubscribing reports a replay gap and the chat reloads (sleep, a daemon restart).
        let gaps = environment["SUNDOWN_UI_TEST_GAP"] == "1"
        return HostConnection(host: host, transportProvider: { _ in
            let attempt = await attempts.next()
            if attempt <= failedConnects {
                throw TransportError.launchFailed("Fixture connection unavailable")
            }
            var options = options
            options.reportsGap = gaps && attempt > failedConnects + 1
            return FixtureTransport(options)
        })
    }
}

/// What a fixture connection plays, read once from the launch's environment.
private struct FixtureOptions: Sendable {
    var pendingPermission = false
    var performance = false
    /// The `prompts` scenario: each answered request brings the next (`answered`).
    var prompts = false
    /// The `tasks` scenario: the chat has started one of each kind of task (`TaskTranscript`).
    var tasks = false
    /// The `showcase` scenario: the README's chats (`ShowcaseTranscript`).
    var showcase = false
    /// Methods answered with an error (SUNDOWN_UI_TEST_FAIL).
    var failing: Set<String> = []
    /// A resubscription after events were seen reports a replay gap (SUNDOWN_UI_TEST_GAP).
    var reportsGap = false
}

private actor FixtureAttempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private final class FixtureTransport: Transport, @unchecked Sendable {
    private let script: FixtureScript
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(_ options: FixtureOptions) {
        script = FixtureScript(options)
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
                    if name != "fixture/pause", let line = try? JSONEncoder().encode(notification) { continuation.yield(line) }
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

    private let options: FixtureOptions
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

    init(_ options: FixtureOptions) { self.options = options }

    private var originalSummary: ThreadSummary {
        .init(threadId: UITestFixture.threadID, title: "Fixture Chat", cwd: "/tmp/sundown-fixture",
              updatedAt: 1_700_000_000_000, status: .idle)
    }

    /// `threads` as the list shows them: what was deleted gone, what was renamed or tagged so.
    private func listed(_ threads: [ThreadSummary]) -> [ThreadSummary] {
        threads.filter { !deleted.contains($0.threadId) }.map { summary in
            var summary = summary
            if let title = titles[summary.threadId] { summary.customTitle = title }
            if let tag = tags[summary.threadId] { summary.tag = tag }
            return summary
        }
    }

    func reply(method: String, params: JSONValue) -> Reply {
        if options.failing.contains(method) { return .init(value: .error("Fixture \(method) failed")) }
        if options.showcase, let reply = showcaseReply(method: method, params: params) { return reply }
        switch method {
        case "initialize":
            return .init(value: .result(json(InitializeResult(
                serverInfo: .init(name: "tether-fixture", version: "1"),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "fixture-host", platform: "darwin", arch: "arm64",
                            home: "/tmp", pid: 1, mode: .daemon),
                claude: .init(path: "/fixture/claude", version: "fixture")
            ))))
        case "model/list": return .init(value: .result(json(ModelListResult(models: []))))
        // As a host whose Claude Code would start in auto mode at medium effort.
        case "session/defaults":
            return .init(value: .result(json(SessionDefaultsResult(model: "sonnet", effort: .medium, permissionMode: .auto))))
        case "thread/list":
            let perf = options.performance ? PerformanceTranscript.otherChats : []
            let followed = options.tasks ? [TaskTranscript.followedChat] : []
            return .init(value: .result(json(ThreadListResult(
                threads: listed(additionalThreads + perf + followed + [originalSummary])))))
        case "thread/tag":
            guard let id = params["threadId"]?.stringValue else { return .init(value: .result([:])) }
            tags[id] = params["tag"]?.stringValue
            return .init(value: .result([:]), notifications: summaryChanged(id))
        case "thread/rename":
            guard let id = params["threadId"]?.stringValue, let title = params["title"]?.stringValue else { return .init(value: .result([:])) }
            titles[id] = title
            return .init(value: .result([:]), notifications: summaryChanged(id))
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
            var summary = (additionalThreads + PerformanceTranscript.otherChats + [TaskTranscript.followedChat])
                .first { $0.threadId == requested } ?? originalSummary
            if let title = titles[requested] { summary.customTitle = title }
            let items: [Item] = options.tasks && (id == UITestFixture.threadID || id == TaskTranscript.followedChat.threadId) ? TaskTranscript.items()
                : options.performance && (id == UITestFixture.threadID || id.hasPrefix("perf-chat-")) ? PerformanceTranscript.history : id == UITestFixture.threadID ? [
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
                items: shown, turns: [], summary: summary,
                historySeq: id == UITestFixture.threadID || id.hasPrefix("perf-chat-") || id == TaskTranscript.followedChat.threadId ? 1 : 0,
                hasMore: shown.count < page.count, tasks: tasks(of: id)
            ))))
        case "thread/subscribe":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            // The performance scenario's other chats aren't live in the daemon, as most of a real
            // host's aren't: they're followed, let go when left, and read again when reopened.
            let status: ThreadStatus = id.hasPrefix("perf-chat-") || id == TaskTranscript.followedChat.threadId ? .notLoaded : .idle
            var reply = Reply(value: .result(json(ThreadSubscribeResult(
                thread: .init(threadId: id, status: status, cwd: "/tmp/sundown-fixture", lastSeq: nextSequence),
                replayed: 0, gap: options.reportsGap && (params["afterSeq"]?.intValue ?? 0) > 1, tasks: tasks(of: id)
            ))))
            if id == UITestFixture.threadID, options.pendingPermission, !sentPermission {
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
            let turn = turnNotifications(threadID: id, input: params["input"])
            return .init(value: .result(json(ThreadStartResult(thread: info, messageId: "fixture-sent-\(nextMessage)"))),
                         notifications: turn + summaryChanged(id))
        case "turn/start":
            let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
            if options.performance { return performanceTurn(threadID: id, input: params["input"]) }
            let notifications = turnNotifications(threadID: id, input: params["input"])
            return .init(value: .result(json(TurnStartResult(turnId: "fixture-turn", messageId: "fixture-sent-\(nextMessage)", queued: false))),
                         notifications: notifications)
        case "thread/sideQuestion":
            let q = params["question"]?.stringValue ?? ""
            return .init(value: .result(["answer": .string("A side answer to “\(q)”.")]))
        case "git/status":
            return .init(value: .result(["isRepo": true, "branch": "main", "files": [["status": "M", "path": "Sources/App.swift"]]]))
        case "git/changes":
            return .init(value: .result(json(GitChangesResult(isRepo: true, root: "/tmp/sundown-fixture", branch: "main", files: [
                WorkingFileChange(path: "Sources/App.swift", status: .modified, hunks: [
                    DiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [
                        " import SwiftUI", "-let greeting = \"Hello\"", "+let greeting = \"Hello, Sundown\"", " print(greeting)",
                    ]),
                ], added: 1, removed: 1, truncatedLines: 0),
            ], omittedFiles: 0))))
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
        // A host whose home (/tmp) holds no directories, above it a readable / and one that isn't.
        case "fs/list":
            // "~" is the home, as the server expands it for listing (thread/start doesn't).
            let path = params["path"]?.stringValue == "~" ? "/tmp" : params["path"]?.stringValue ?? ""
            let entries: [FsListResult.Entry]? = switch path {
            case "/": [.init(name: "private", path: "/private", isDirectory: true, size: 0),
                       .init(name: "tmp", path: "/tmp", isDirectory: true, size: 0)]
            case "/tmp": [.init(name: "notes.txt", path: "/tmp/notes.txt", isDirectory: false, size: 12)]
            default: nil
            }
            guard let entries else { return .init(value: .error("Permission denied: \(path)")) }
            return .init(value: .result(json(FsListResult(entries: entries))))
        case "workflow/agentItems":
            let agent = params["agentId"]?.stringValue ?? ""
            return .init(value: .result(["items": json(WorkflowSample.agentItems(agentId: agent, now: TaskTranscript.workflowNow))]))
        default: return .init(value: .error("Unexpected fixture method: \(method)"))
        }
    }

    /// What every client is told when a chat's summary changes (`thread/summaryChanged`), as the
    /// list now has it.
    private func summaryChanged(_ id: String) -> [(String, JSONValue)] {
        let all = listed(additionalThreads + (options.showcase ? ShowcaseTranscript.summaries : PerformanceTranscript.otherChats)
                         + [originalSummary])
        guard let summary = all.first(where: { $0.threadId == id }) else { return [] }
        return [("thread/summaryChanged", json(ThreadSummaryChangedNotification(summary: summary)))]
    }

    /// The tasks scenario's chats' tasks, live and followed alike.
    private func tasks(of id: String) -> [TaskState] {
        options.tasks && (id == UITestFixture.threadID || id == TaskTranscript.followedChat.threadId) ? TaskTranscript.tasks() : []
    }

    // MARK: The showcase scenario

    /// The showcase's answer to `method`, or nil for the fixture's usual one.
    private func showcaseReply(method: String, params: JSONValue) -> Reply? {
        let id = params["threadId"]?.stringValue ?? ShowcaseTranscript.mainThreadID
        switch method {
        case "model/list": return .init(value: .result(json(ModelListResult(models: ShowcaseTranscript.models))))
        case "account/read": return .init(value: .result(json(AccountReadResult(account: .init(subscriptionType: "max")))))
        case "session/defaults":
            return .init(value: .result(json(SessionDefaultsResult(model: "opus", effort: .high, permissionMode: .auto))))
        case "thread/list":
            return .init(value: .result(json(ThreadListResult(threads: listed(additionalThreads + ShowcaseTranscript.summaries)))))
        case "thread/read":
            guard let summary = (additionalThreads + ShowcaseTranscript.summaries).first(where: { $0.threadId == id }) else { return nil }
            let items = id == ShowcaseTranscript.reviewThreadID ? TaskTranscript.items() + ShowcaseTranscript.reviewItems()
                : ShowcaseTranscript.items(for: id)
            return .init(value: .result(json(ThreadReadResult(items: items, turns: [], summary: summary, historySeq: 1, hasMore: false,
                                                              tasks: ShowcaseTranscript.tasks(of: id)))))
        case "thread/subscribe":
            let status: ThreadStatus = switch id {
            case ShowcaseTranscript.flakyThreadID: .requiresAction
            case ShowcaseTranscript.reviewThreadID: .running
            default: .idle
            }
            var reply = Reply(value: .result(json(ThreadSubscribeResult(
                thread: .init(threadId: id, status: status, cwd: ShowcaseTranscript.cwd(of: id), model: "opus", appliedEffort: .high,
                              permissionMode: .auto, mcpServers: ShowcaseTranscript.mcpServers, lastSeq: nextSequence),
                replayed: 0, gap: false, tasks: ShowcaseTranscript.tasks(of: id)))))
            if id == ShowcaseTranscript.flakyThreadID, !sentPermission {
                sentPermission = true
                reply.requests = [(.number(900), "permission/request", json(ShowcaseTranscript.permission(threadID: id)))]
            }
            return reply
        case "thread/contextUsage": return .init(value: .result(json(ThreadContextUsageResult(usage: ShowcaseTranscript.contextUsage))))
        case "turn/start": return showcaseTurn(threadID: id, input: params["input"])
        case "git/status":
            return .init(value: .result(ShowcaseTranscript.gitStatus(cwd: params["cwd"]?.stringValue ?? "")))
        case "git/changes":
            return .init(value: .result(json(ShowcaseTranscript.gitChanges(cwd: params["cwd"]?.stringValue ?? ""))))
        case "fs/search":
            let query = (params["query"]?.stringValue ?? "").lowercased()
            let paths = ShowcaseTranscript.searchablePaths.filter { query.isEmpty || $0.lowercased().contains(query) }
            return .init(value: .result(["paths": .array(paths.map { .string($0) })]))
        default: return nil
        }
    }

    /// A prompt sent in the showcase: the turn starts, Thinking, then `ShowcaseTranscript.liveReply`
    /// streamed in the order a real host sends it, and the turn ends.
    private func showcaseTurn(threadID: String, input: JSONValue?) -> Reply {
        scriptedTurn(threadID: threadID, input: input, idPrefix: "showcase", defaultText: "",
                     startedAt: { _ in ShowcaseTranscript.now }) { firstSeq, turn in
            // A moment's thought before the first call.
            Array(repeating: ("fixture/pause", [:]), count: 60)
                + ShowcaseTranscript.liveReply(threadID: threadID, turn: turn, firstSeq: firstSeq)
        }
    }

    /// A turn the fixture plays by itself: the turn, the prompt and "running" at once, then `stream`
    /// (notifications numbered from the `firstSeq` it is given, `fixture/pause`s taking none), then
    /// the turn's end and "idle", in the order a real host sends them.
    private func scriptedTurn(threadID: String, input: JSONValue?, idPrefix: String, defaultText: String,
                              startedAt: (_ turn: Int) -> Double,
                              stream: (_ firstSeq: Int, _ turn: Int) -> [(String, JSONValue)]) -> Reply {
        nextMessage += 1
        let turn = nextMessage
        let text = input?.arrayValue?.first?["text"]?.stringValue ?? defaultText
        let time = startedAt(turn)
        let user = Item.userMessage(.init(id: "\(idPrefix)-sent-\(turn)", createdAt: time, content: [.text(.init(text: text))]))
        var reply = Reply(value: .result(json(TurnStartResult(turnId: "\(idPrefix)-turn-\(turn)", messageId: "\(idPrefix)-sent-\(turn)",
                                                              queued: false))))
        let started = Turn(id: "\(idPrefix)-turn-\(turn)", status: .inProgress, startedAt: time)
        var completed = started
        completed.status = .completed
        reply.notifications = [
            ("turn/started", json(TurnStartedNotification(threadId: threadID, seq: nextSequence + 1, turn: started))),
            ("item/started", json(ItemStartedNotification(threadId: threadID, seq: nextSequence + 2, item: user))),
            ("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(nextSequence + 3)), "status": "running"]),
        ]
        reply.stream = stream(nextSequence + 4, turn)
        let last = nextSequence + 4 + reply.stream.filter { $0.0 != "fixture/pause" }.count
        reply.stream.append(("turn/completed", json(TurnCompletedNotification(threadId: threadID, seq: last, turn: completed))))
        reply.stream.append(("thread/status/changed", ["threadId": .string(threadID), "seq": .number(Double(last + 1)), "status": "idle"]))
        nextSequence = last + 1
        return reply
    }

    // MARK: The prompts scenario

    /// The app's answer to request `id`, said in the chat as a reply ("Answered: " and the answer's
    /// JSON, keys sorted), and the request that comes after it: the permission asked on subscribe
    /// (900), a second permission, a question, a form, then a question too long for the window.
    func answered(id: JSONValue, result: JSONValue) -> [JSONValue] {
        guard options.prompts, let answered = id.intValue else { return [] }
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
        scriptedTurn(threadID: threadID, input: input, idPrefix: "perf", defaultText: "Fixture input",
                     startedAt: { 1_900_000_000_000 + Double($0 * 1000) }) { firstSeq, turn in
            PerformanceTranscript.reply(threadID: threadID, firstSeq: firstSeq, turn: turn)
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
        items.append(.agentMessage(.init(id: "perf-answer-\(turn)", createdAt: t + 500, text: answer(turn))))
        return items
    }

    /// SUNDOWN_PERF_VARIED=1 makes the answers' heights vary as real ones do: now and then a very
    /// long one (a dozen sections, or a 300-line code block), sometimes a single line.
    private static func answer(_ turn: Int) -> String {
        guard ProcessInfo.processInfo.environment["SUNDOWN_PERF_VARIED"] == "1" else { return markdown(section: turn) }
        switch turn % 11 {
        case 0: return (0..<12).map { markdown(section: turn * 100 + $0) }.joined(separator: "\n\n")
        case 3: return "Done."
        case 5: return "Here is the file:\n\n```swift\n" + (0..<300).map { "let value\($0) = compute(\($0)) // line \($0)" }.joined(separator: "\n") + "\n```"
        case 7: return "Short note."
        default: return markdown(section: turn)
        }
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
            return .toolCall(Item.ToolCall(id: id, createdAt: time, name: "Edit", kind: .fileEdit,
                                   input: ["file_path": .string(file), "old_string": .string("let blocks = parse(text)"),
                                           "new_string": .string("let blocks = cache.blocks(for: text)")],
                                   status: status, outputText: failed ? "String to replace not found in file." : "The file \(file) has been updated.",
                                   isError: failed ? true : nil).withComparedEdit)
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
/// background command, a monitor and an MCP tool, as the SDK reports them, running and finished;
/// and messages the person didn't type (Claude Code's, another session's, a compaction's summary).
/// A second chat holds the same items, followed rather than live, as most of a host's chats are.
/// Times as seconds before now, and the calls the task scenarios (`TaskTranscript`,
/// `ShowcaseTranscript.reviewItems`) and the Tasks previews are made of.
struct TaskClock {
    let now = Date().timeIntervalSince1970 * 1000

    func ago(_ seconds: Double) -> Double { now - seconds * 1000 }

    func call(_ id: String, _ name: String, _ kind: ToolKind, _ input: JSONValue, status: ToolStatus = .completed,
              output: String? = nil, parent: String? = nil, at seconds: Double) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: ago(seconds), name: name, kind: kind, input: input,
                        status: status, outputText: output))
    }
}

enum TaskTranscript {
    static let followedChat = ThreadSummary(threadId: "tasks-followed", title: "Followed Tasks", cwd: "/tmp/sundown-fixture",
                                            updatedAt: 1_699_999_999_000, status: .notLoaded)

    /// When the workflow ran: before the rest of the chat.
    static var workflowNow: Double { Date().timeIntervalSince1970 * 1000 - 500_000 }

    static func items() -> [Item] {
        let clock = TaskClock()
        let root = "/tmp/sundown-fixture/Sources/"
        return WorkflowSample.items(now: workflowNow, running: false) + [
            .userMessage(.init(id: "tasks-user", createdAt: clock.ago(400),
                               content: [.text(.init(text: "Review the changes, and find which views read thread.items."))])),
            clock.call("agent-1", "Task", .subagent, [
                "subagent_type": "Explore", "description": "Find every SwiftUI view",
                "prompt": "Find every SwiftUI view and list which read `thread.items`.",
            ], status: .running, at: 100),
            clock.call("agent-1-grep", "Grep", .grep, ["pattern": "thread\\.items", "path": .string(root)],
                       output: "TranscriptFind.swift:88\nThreadView.swift:41", parent: "agent-1", at: 95),
            .agentMessage(.init(id: "agent-1-reply", parentToolUseId: "agent-1", createdAt: clock.ago(80),
                                text: "Most views read `rows`, not `items`. Two exceptions so far:\n\n- `TranscriptFind` builds its search text from items.\n- `ThreadView` reads the last item.")),
            clock.call("bg-call", "Bash", .bash, [
                "command": "swift test", "description": "Run the tests", "run_in_background": true,
            ], output: "Command running in background", parent: "agent-1", at: 70),
            clock.call("agent-2", "Task", .subagent, [
                "description": "Check how TranscriptFind reads items",
                "prompt": "Read TranscriptFind.swift and say how it builds its search text.",
            ], status: .running, parent: "agent-1", at: 34),
            clock.call("agent-2-read", "Read", .fileRead, ["file_path": .string(root + "TranscriptFind.swift")],
                       status: .running, parent: "agent-2", at: 5),
            clock.call("failed-call", "Bash", .bash, ["command": "xcodebuild -scheme Sundown build", "run_in_background": true],
                       output: "** BUILD FAILED **", at: 300),
            .compaction(.init(id: "tasks-compaction", createdAt: clock.ago(4), preTokens: 84_000)),
            .userMessage(.init(id: "tasks-summary", createdAt: clock.ago(4), content: [.text(.init(text:
                "This session is being continued from a previous conversation that ran out of context."))],
                               synthetic: true, origin: "compaction")),
            .userMessage(.init(id: "tasks-claude-code", createdAt: clock.ago(3), content: [.text(.init(text:
                "Caveat: the messages below were generated while running local commands."))], synthetic: true)),
            .userMessage(.init(id: "tasks-peer", createdAt: clock.ago(2), content: [.text(.init(text: "The release notes are drafted."))],
                               synthetic: true, origin: "peer", originName: "release-notes")),
        ]
    }

    /// The chat's tasks as the daemon sends them: the finished workflow's, two agents (one started
    /// by the other) and a background command the first started, a monitor, an MCP tool, and a
    /// build that failed.
    static func tasks() -> [TaskState] {
        let clock = TaskClock()
        return WorkflowSample.tasks(now: workflowNow, running: false) + [
            TaskState(id: "agent-1", toolUseId: "agent-1", taskId: "agent-task-1", kind: .agent, taskType: "local_agent",
                      title: "Find every SwiftUI view", status: .running, startedAt: clock.ago(100)),
            TaskState(id: "agent-2", parentId: "agent-1", toolUseId: "agent-2", taskId: "agent-task-2", kind: .agent,
                      taskType: "local_agent", title: "Check how TranscriptFind reads items", status: .running,
                      startedAt: clock.ago(34)),
            TaskState(id: "bg-call", parentId: "agent-1", toolUseId: "bg-call", taskId: "bg-tests", kind: .command,
                      taskType: "local_bash", title: "swift test", status: .running, startedAt: clock.ago(70), backgrounded: true),
            TaskState(id: "task:monitor-1", taskId: "monitor-1", kind: .monitor, taskType: "monitor",
                      title: "Watch CI on the pull request", status: .running, startedAt: clock.ago(60)),
            TaskState(id: "task:mcp-1", taskId: "mcp-1", kind: .mcpTool, taskType: "mcp_task", title: "Run all tests in Xcode",
                      status: .done, summary: "412 tests passed, 3 skipped.", usage: .init(durationMs: 243_000, toolUses: 1)),
            TaskState(id: "failed-call", toolUseId: "failed-call", taskId: "build-1", kind: .command, taskType: "local_bash",
                      title: "xcodebuild -scheme Sundown build", status: .failed, startedAt: clock.ago(300),
                      backgrounded: true, summary: "Build failed", usage: .init(durationMs: 123_000)),
        ]
    }
}

func json<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
