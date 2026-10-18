import Foundation
import SundownKit
import TetherProtocol

/// A daemon's chats and what it says of itself, as `FakeHost.serve(_:)` serves them: the UI-test
/// fixture's scenarios (SUNDOWN_UI_TEST_SCENARIO), the chats previews seed from, and a test's own.
///
/// What depends on the time (a task's start, a reply's age) is worked out when it's read, as a
/// daemon would have it then: a chat's items and tasks are functions.
public struct FixtureScenario: Sendable {
    /// The chats as the list shows them, after any started or forked on the connection.
    public var chats: [FixtureChat]
    public var models: [ModelInfo] = []
    /// Unanswered without one, as a host whose account can't be read.
    public var account: AccountInfo?
    /// What Claude Code would start a chat with on this host.
    public var sessionDefaults = SessionDefaultsResult(model: "sonnet", effort: .medium, permissionMode: .auto)
    /// What a subscription says of a chat started or forked here, or one the host doesn't list.
    public var otherChatInfo = ThreadInfo(threadId: "", status: .idle, cwd: FixtureScenario.directory, lastSeq: 0)
    /// What a prompt sent to a chat (`turn/start`) gets back.
    public var reply: @Sendable (FixturePrompt) -> FixtureReply = FixtureReply.quick
    public var gitStatus: @Sendable (_ cwd: String) -> JSONValue = { _ in
        ["isRepo": true, "branch": "main", "files": [["status": "M", "path": "Sources/App.swift"]]]
    }
    public var gitChanges: @Sendable (_ cwd: String) -> GitChangesResult = { _ in FixtureScenario.changes }
    /// What `@` finds, filtered by what's typed.
    public var searchablePaths: [String] = []
    /// Unanswered without one.
    public var contextUsage: JSONValue?
    /// A workflow agent's transcript, by its id.
    public var agentItems: @Sendable (_ agentId: String) -> [Item] = { agent in
        WorkflowSample.agentItems(agentId: agent, now: TaskTranscript.workflowNow)
    }
    /// What the host sends once the client answers its request `id` with `result`: notifications
    /// numbered from `firstSeq`, and its next request.
    public var answered: (@Sendable (_ id: Int, _ result: JSONValue, _ firstSeq: Int) -> [FakeHost.Message])?
    /// Methods answered with an error ("Fixture <method> failed").
    public var failing: Set<String> = []
    /// A subscription after events were seen reports a replay gap.
    public var reportsGap = false

    public init(chats: [FixtureChat]) {
        self.chats = chats
    }

    /// Where the fixture's chats are.
    public static let directory = "/tmp/sundown-fixture"

    /// The working tree every scenario but the showcase has: one line changed.
    static let changes = GitChangesResult(isRepo: true, root: directory, branch: "main", files: [
        WorkingFileChange(path: "Sources/App.swift", status: .modified, hunks: [
            DiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [
                " import SwiftUI", "-let greeting = \"Hello\"", "+let greeting = \"Hello, Sundown\"", " print(greeting)",
            ]),
        ], added: 1, removed: 1, truncatedLines: 0),
    ], omittedFiles: 0)
}

/// One chat a scenario holds.
public struct FixtureChat: Sendable {
    public var summary: ThreadSummary
    /// Its items, oldest first, which reads page from the end.
    public var items: @Sendable () -> [Item]
    /// Its tasks, as reads and subscriptions carry them.
    public var tasks: @Sendable () -> [TaskState]
    /// A read's `historySeq`.
    public var historySeq: Int
    /// What a subscription says of it; its `lastSeq` is the host's.
    public var info: ThreadInfo
    /// A request the host makes the first time the chat is subscribed to on a connection.
    public var request: FixtureRequest?

    public init(summary: ThreadSummary, items: @escaping @Sendable () -> [Item] = { [] },
                tasks: @escaping @Sendable () -> [TaskState] = { [] }, historySeq: Int = 1, info: ThreadInfo? = nil,
                request: FixtureRequest? = nil) {
        self.summary = summary
        self.items = items
        self.tasks = tasks
        self.historySeq = historySeq
        self.info = info ?? ThreadInfo(threadId: summary.threadId, status: .idle, cwd: FixtureScenario.directory, lastSeq: 0)
        self.request = request
        self.info.threadId = summary.threadId
    }

    public var id: String { summary.threadId }
}

/// A request of the host's own: a permission, a question, a form.
public struct FixtureRequest: Sendable {
    public var method: String
    public var params: JSONValue

    public init(_ method: String, _ params: some Encodable) {
        self.method = method
        self.params = json(params)
    }
}

/// A prompt sent to a chat, as the fixture's reply sees it.
public struct FixturePrompt: Sendable {
    public var threadID: String
    /// The prompt's first text, if it has one.
    public var text: String?
    /// The how-manyth prompt on the connection, counting from 1: it keeps each reply's ids apart.
    public var turn: Int
    /// The first sequence number the reply's notifications take.
    public var firstSeq: Int
}

/// A prompt's answer and what follows it. The host numbers its next notifications after these.
public struct FixtureReply: Sendable {
    public var result: TurnStartResult
    /// Sent with the answer.
    public var then: [FakeHost.Message]
    /// Streamed after it, a frame at a time.
    public var stream: [FakeHost.Message]

    var notificationCount: Int { (then + stream).filter(\.isNotification).count }

    /// "Scripted response." at once, after the prompt, and the chat idle; a prompt asking to
    /// "suggest a task" gets one, as session tools' suggest_task would.
    @Sendable public static func quick(_ prompt: FixturePrompt) -> FixtureReply {
        let thread = prompt.threadID, n = prompt.turn, seq = prompt.firstSeq
        let text = prompt.text ?? "Fixture input"
        let timestamp = 1_700_000_000_000.0 + Double(n * 10)
        let user = Item.userMessage(.init(id: "fixture-sent-\(n)", createdAt: timestamp, content: [.text(.init(text: text))]))
        let answerID = "fixture-stream-\(n)"
        let answer = Item.agentMessage(.init(id: answerID, createdAt: timestamp + 1, text: ""))
        var then: [FakeHost.Message] = [
            .notification("item/started", json(ItemStartedNotification(threadId: thread, seq: seq, item: user))),
            .notification("item/started", json(ItemStartedNotification(threadId: thread, seq: seq + 1, item: answer))),
            .notification("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: thread, seq: seq + 2, itemId: answerID, delta: "Scripted "))),
            .notification("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                threadId: thread, seq: seq + 3, itemId: answerID, delta: "response."))),
            .notification("thread/status/changed", ["threadId": .string(thread), "seq": .number(Double(seq + 4)), "status": "idle"]),
        ]
        if text.localizedCaseInsensitiveContains("suggest a task") {
            then.append(.notification("thread/taskSuggested", ["threadId": .string(thread), "seq": .number(Double(seq + 5)),
                                                                "title": "Write the release notes", "prompt": "Draft release notes for 0.6."]))
        }
        return .init(result: TurnStartResult(turnId: "fixture-turn", messageId: "fixture-sent-\(n)", queued: false), then: then, stream: [])
    }

    /// A turn as a real host plays it: the turn, the prompt and "running" with the answer, then
    /// `body` (numbered from the `firstSeq` it's given; pauses take none) a frame at a time, then the
    /// turn's end and "idle".
    public static func scripted(_ prompt: FixturePrompt, idPrefix: String, defaultText: String, startedAt: Double,
                                body: (_ firstSeq: Int) -> [FakeHost.Message]) -> FixtureReply {
        let thread = prompt.threadID, n = prompt.turn, seq = prompt.firstSeq
        let user = Item.userMessage(.init(id: "\(idPrefix)-sent-\(n)", createdAt: startedAt,
                                          content: [.text(.init(text: prompt.text ?? defaultText))]))
        let started = Turn(id: "\(idPrefix)-turn-\(n)", status: .inProgress, startedAt: startedAt)
        var completed = started
        completed.status = .completed
        var stream = body(seq + 3)
        let last = seq + 3 + stream.filter(\.isNotification).count
        stream.append(.notification("turn/completed", json(TurnCompletedNotification(threadId: thread, seq: last, turn: completed))))
        stream.append(.notification("thread/status/changed", ["threadId": .string(thread), "seq": .number(Double(last + 1)), "status": "idle"]))
        return .init(
            result: TurnStartResult(turnId: "\(idPrefix)-turn-\(n)", messageId: "\(idPrefix)-sent-\(n)", queued: false),
            then: [
                .notification("turn/started", json(TurnStartedNotification(threadId: thread, seq: seq, turn: started))),
                .notification("item/started", json(ItemStartedNotification(threadId: thread, seq: seq + 1, item: user))),
                .notification("thread/status/changed", ["threadId": .string(thread), "seq": .number(Double(seq + 2)), "status": "running"]),
            ],
            stream: stream)
    }
}

// MARK: The UI-test scenarios

extension FixtureScenario {
    /// The fixture's own chat: one prompt and its answer.
    public static let fixtureChat = FixtureChat(
        summary: .init(threadId: UITestFixture.threadID, title: "Fixture Chat", cwd: directory, updatedAt: 1_700_000_000_000, status: .idle),
        items: {
            [.userMessage(.init(id: "fixture-user", createdAt: 1_700_000_000_000, content: [.text(.init(text: "Summarize this project"))])),
             .agentMessage(.init(id: "fixture-answer", createdAt: 1_700_000_000_001, text: "Fixture answer from the local transport."))]
        })

    /// One short chat (no SUNDOWN_UI_TEST_SCENARIO).
    public static var standard: FixtureScenario { FixtureScenario(chats: [fixtureChat]) }

    /// The short chat, with a permission asked as it's subscribed to, then another, a question, a
    /// form and a question too long for the window, each once the one before is answered, each
    /// answer said in the chat as a reply ("Answered: " and its JSON, keys sorted) (`prompts`).
    public static var prompts: FixtureScenario {
        var scenario = standard
        scenario.chats[0].request = FixtureRequest("permission/request", PermissionRequestParams(
            threadId: UITestFixture.threadID, requestId: "fixture-permission", toolUseId: "fixture-tool",
            toolName: "Bash", input: ["command": "echo fixture"], title: "Allow fixture command?", suppressAlwaysAllowRule: true))
        scenario.answered = { id, result, seq in
            let thread = UITestFixture.threadID
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let text = (try? encoder.encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            let item = Item.agentMessage(.init(id: "fixture-answered-\(id)", createdAt: 1_700_000_000_100 + Double(id), text: "Answered: \(text)"))
            var out: [FakeHost.Message] = [
                .notification("item/started", json(ItemStartedNotification(threadId: thread, seq: seq, item: item))),
                .notification("item/completed", json(ItemCompletedNotification(threadId: thread, seq: seq + 1, item: item))),
            ]
            let next: FixtureRequest? = switch id {
            case 900: FixtureRequest("permission/request", PermissionRequestParams(
                threadId: thread, requestId: "fixture-second-permission", toolUseId: "fixture-second-tool", toolName: "Bash",
                input: ["command": "echo second"], title: "Allow second command?", suppressAlwaysAllowRule: true))
            case 901: FixtureRequest("question/request", question(threadID: thread, long: false))
            case 902: FixtureRequest("elicitation/request", ElicitationRequestParams(
                threadId: thread, requestId: "fixture-elicitation", serverName: "Fixture Server",
                message: "Tell the server about the project.", requestedSchema: [
                    "type": "object",
                    "properties": ["name": ["type": "string", "title": "Project Name", "description": "What to call it"]],
                    "required": ["name"],
                ]))
            case 903: FixtureRequest("question/request", question(threadID: thread, long: true))
            default: nil
            }
            if let next { out.append(.request(id: .number(Double(id + 1)), next.method, next.params)) }
            return out
        }
        return scenario
    }

    /// One question with three choices, or one so long, with thirty long choices, that the card is
    /// taller than the window.
    private static func question(threadID: String, long: Bool) -> QuestionRequestParams {
        let filler = long ? String(repeating: "This sentence makes the question much longer than a card expects. ", count: 60) : ""
        let options: [QuestionRequestParams.Question.Option] = long
            ? (1...30).map { .init(label: "Option number \($0) with a rather long label that goes on",
                                   description: String(repeating: "Describes option \($0) at length. ", count: 6)) }
            : [.init(label: "Postgres", description: "A server"), .init(label: "SQLite", description: "A file"),
               .init(label: "MySQL", description: "Another server")]
        return QuestionRequestParams(threadId: threadID, requestId: long ? "fixture-long-question" : "fixture-question",
                                     toolUseId: long ? "fixture-long-question-tool" : "fixture-question-tool", questions: [
            .init(question: "Which database should we use? " + filler, header: "Database", multiSelect: false, options: options),
        ])
    }

    /// Three long chats, the fixture's live and two followed, and a long working reply for each
    /// prompt (`performance`).
    public static var performance: FixtureScenario {
        let history: @Sendable () -> [Item] = { PerformanceTranscript.history }
        // Not live in the daemon, as most of a real host's chats aren't: followed, let go when
        // left, and read again when reopened.
        var scenario = FixtureScenario(chats: PerformanceTranscript.otherChats.map {
            FixtureChat(summary: $0, items: history, info: .init(threadId: $0.threadId, status: .notLoaded, cwd: directory, lastSeq: 0))
        } + [FixtureChat(summary: fixtureChat.summary, items: history)])
        scenario.reply = { prompt in
            FixtureReply.scripted(prompt, idPrefix: "perf", defaultText: "Fixture input",
                                  startedAt: 1_900_000_000_000 + Double(prompt.turn * 1000)) { firstSeq in
                PerformanceTranscript.reply(threadID: prompt.threadID, firstSeq: firstSeq, turn: prompt.turn)
                    .map { .notification($0.0, $0.1) }
            }
        }
        return scenario
    }

    /// The fixture's chat holding one of each kind of task (`TaskTranscript`), and a second holding
    /// the same, followed rather than live (`tasks`).
    public static var tasks: FixtureScenario {
        let items: @Sendable () -> [Item] = { TaskTranscript.items() }
        let tasks: @Sendable () -> [TaskState] = { TaskTranscript.tasks() }
        let followed = TaskTranscript.followedChat
        return FixtureScenario(chats: [
            FixtureChat(summary: followed, items: items, tasks: tasks,
                        info: .init(threadId: followed.threadId, status: .notLoaded, cwd: directory, lastSeq: 0)),
            FixtureChat(summary: fixtureChat.summary, items: items, tasks: tasks),
        ])
    }

    private static func showcaseChat(_ summary: ThreadSummary) -> FixtureChat {
        let id = summary.threadId
        let status: ThreadStatus = switch id {
        case ShowcaseTranscript.flakyThreadID: .requiresAction
        case ShowcaseTranscript.reviewThreadID: .running
        default: .idle
        }
        let items: @Sendable () -> [Item] = if id == ShowcaseTranscript.reviewThreadID {
            { TaskTranscript.items() + ShowcaseTranscript.reviewItems() }
        } else {
            { ShowcaseTranscript.items(for: id) }
        }
        let request: FixtureRequest? = id == ShowcaseTranscript.flakyThreadID
            ? FixtureRequest("permission/request", ShowcaseTranscript.permission(threadID: id)) : nil
        return FixtureChat(summary: summary, items: items, tasks: { ShowcaseTranscript.tasks(of: id) },
                           info: ShowcaseTranscript.info(id, status: status), request: request)
    }

    /// The README's chats (`ShowcaseTranscript`, `showcase`).
    public static var showcase: FixtureScenario {
        var scenario = FixtureScenario(chats: ShowcaseTranscript.summaries.map(showcaseChat))
        scenario.models = ShowcaseTranscript.models
        scenario.account = .init(subscriptionType: "max")
        scenario.sessionDefaults = .init(model: "opus", effort: .high, permissionMode: .auto)
        scenario.otherChatInfo = ShowcaseTranscript.info("", status: .idle)
        scenario.gitStatus = { ShowcaseTranscript.gitStatus(cwd: $0) }
        scenario.gitChanges = { ShowcaseTranscript.gitChanges(cwd: $0) }
        scenario.searchablePaths = ShowcaseTranscript.searchablePaths
        scenario.contextUsage = ShowcaseTranscript.contextUsage
        // Whatever was asked, a moment's thought, then the background refresh the last reply offered.
        scenario.reply = { prompt in
            FixtureReply.scripted(prompt, idPrefix: "showcase", defaultText: "", startedAt: ShowcaseTranscript.now) { firstSeq in
                Array(repeating: .pause, count: 60)
                    + ShowcaseTranscript.liveReply(threadID: prompt.threadID, turn: prompt.turn, firstSeq: firstSeq)
                        .map { .notification($0.0, $0.1) }
            }
        }
        return scenario
    }
}
