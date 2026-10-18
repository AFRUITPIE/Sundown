import Foundation
import Synchronization
import SundownKit
import TetherProtocol

extension FakeHost {
    /// Answers as a daemon holding `scenario`'s chats: the catalog, the list, reads paged from the
    /// end, subscriptions (each chat's request asked the first time), Rename, Tag, Delete and
    /// Duplicate as the list and reads then show them, a chat started from New Chat (its prompt's
    /// echo first), a prompt's reply, the requests that follow the client's answers, and the rest
    /// of what a window asks: a side question, the working tree, Restore Code, commands, files and
    /// directories, a workflow agent's transcript and the context's breakdown.
    public func serve(_ scenario: FixtureScenario) {
        let chats = FixtureChats(scenario)
        answer("model/list", with: ModelListResult(models: scenario.models))
        if let account = scenario.account { answer("account/read", with: AccountReadResult(account: account)) }
        answer("session/defaults", with: scenario.sessionDefaults)
        answer("thread/list") { _ in .result(ThreadListResult(threads: chats.listed())) }
        answer("thread/read") { chats.read($0.params) }
        answer("thread/subscribe") { chats.subscribe($0.params) }
        answer("thread/unsubscribe", .result([:]))
        answer("thread/tag") { chats.tag($0.params) }
        answer("thread/rename") { chats.rename($0.params) }
        answer("thread/delete") { chats.delete($0.params) }
        answer("thread/fork") { chats.fork($0.params) }
        answer("thread/start") { chats.start($0) }
        answer("turn/start") { chats.turn($0.params) }
        answer("thread/sideQuestion") { call in
            .result(["answer": .string("A side answer to “\(call.params["question"]?.stringValue ?? "")”.")])
        }
        answer("git/status") { .result(scenario.gitStatus($0.params["cwd"]?.stringValue ?? "")) }
        answer("git/changes") { .result(scenario.gitChanges($0.params["cwd"]?.stringValue ?? "")) }
        answer("thread/rewindFiles") { chats.rewind($0.params) }
        answer("command/list", .result(["commands": [
            ["name": "compact", "description": "Compact the conversation"],
            ["name": "context", "description": "Show context usage"],
            ["name": "review", "description": "Review the current changes"],
            ["name": "help", "description": "Show available commands"],
            ["name": "status", "description": "Show session status"],
        ]]))
        answer("fs/search") { call in
            let query = (call.params["query"]?.stringValue ?? "").lowercased()
            let paths = scenario.searchablePaths.filter { query.isEmpty || $0.lowercased().contains(query) }
            return .result(["paths": .array(paths.map { .string($0) })])
        }
        answer("fs/list") { FixtureChats.list($0.params) }
        answer("workflow/agentItems") { call in
            .result(["items": json(scenario.agentItems(call.params["agentId"]?.stringValue ?? ""))])
        }
        if let usage = scenario.contextUsage {
            answer("thread/contextUsage", with: ThreadContextUsageResult(usage: usage))
        }
        whenAnswered { id, result in chats.answered(id, result) }
        for method in scenario.failing { fail(method, "Fixture \(method) failed") }
    }
}

/// The chats a `serve`d host holds, and what's been done to them on the connection.
private final class FixtureChats: Sendable {
    private struct State {
        var nextSequence = 1
        var nextMessage = 0
        /// Chats started or forked here, newest first.
        var started: [ThreadSummary] = []
        var titles: [String: String] = [:]
        var tags: [String: String] = [:]
        var deleted: Set<String> = []
        /// A fork's id, and the chat whose items it reads.
        var forks: [String: String] = [:]
        /// The chats whose request has been made.
        var asked: Set<String> = []
        /// How many times Restore Code has run.
        var rewound = 0
    }

    private let scenario: FixtureScenario
    private let state = Mutex(State())

    init(_ scenario: FixtureScenario) { self.scenario = scenario }

    private func chat(_ id: String) -> FixtureChat? { scenario.chats.first { $0.id == id } }

    private func summaries(_ s: State) -> [ThreadSummary] { s.started + scenario.chats.map(\.summary) }

    /// The chats as the list shows them: what was deleted gone, what was renamed or tagged so.
    private func listed(_ s: State) -> [ThreadSummary] {
        summaries(s).filter { !s.deleted.contains($0.threadId) }.map { summary in
            var summary = summary
            if let title = s.titles[summary.threadId] { summary.customTitle = title }
            if let tag = s.tags[summary.threadId] { summary.tag = tag }
            return summary
        }
    }

    func listed() -> [ThreadSummary] { state.withLock { listed($0) } }

    /// What every client is told when a chat's summary changes, as the list now has it.
    private func summaryChanged(_ id: String, _ s: State) -> [FakeHost.Message] {
        guard let summary = listed(s).first(where: { $0.threadId == id }) else { return [] }
        return [.notification("thread/summaryChanged", json(ThreadSummaryChangedNotification(summary: summary)))]
    }

    func read(_ params: JSONValue) -> FakeHost.Answer {
        let requested = params["threadId"]?.stringValue ?? UITestFixture.threadID
        let (summary, source) = state.withLock { s in
            // A fork reads as the chat it was made from, under its own name.
            var summary = summaries(s).first { $0.threadId == requested } ?? FixtureScenario.fixtureChat.summary
            if let title = s.titles[requested] { summary.customTitle = title }
            return (summary, s.forks[requested] ?? requested)
        }
        let chat = chat(source)
        // Paged from the end, as the server does.
        let items = chat?.items() ?? []
        var page = items[...]
        if let before = params["before"]?.stringValue, let i = page.firstIndex(where: { $0.id == before }) {
            page = page[..<i]
        }
        let limit = params["limit"]?.intValue ?? page.count
        let shown = Array(page.suffix(limit))
        return .result(ThreadReadResult(items: shown, turns: [], summary: summary, historySeq: chat?.historySeq ?? 0,
                                        hasMore: shown.count < page.count, tasks: chat?.tasks() ?? []))
    }

    func subscribe(_ params: JSONValue) -> FakeHost.Answer {
        let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
        let chat = chat(id)
        let (lastSeq, request) = state.withLock { s in
            let request = chat?.request.flatMap { s.asked.insert(id).inserted ? $0 : nil }
            return (s.nextSequence, request)
        }
        var info = chat?.info ?? scenario.otherChatInfo
        info.threadId = id
        info.lastSeq = lastSeq
        var answer = FakeHost.Answer.result(ThreadSubscribeResult(
            thread: info, replayed: 0, gap: scenario.reportsGap && (params["afterSeq"]?.intValue ?? 0) > 1, tasks: chat?.tasks() ?? []))
        if let request { answer.then = [.request(id: 900, request.method, request.params)] }
        return answer
    }

    func tag(_ params: JSONValue) -> FakeHost.Answer {
        guard let id = params["threadId"]?.stringValue else { return .result([:]) }
        let changed = state.withLock { s in
            s.tags[id] = params["tag"]?.stringValue
            return summaryChanged(id, s)
        }
        return .init(.result([:]), then: changed)
    }

    func rename(_ params: JSONValue) -> FakeHost.Answer {
        guard let id = params["threadId"]?.stringValue, let title = params["title"]?.stringValue else { return .result([:]) }
        let changed = state.withLock { s in
            s.titles[id] = title
            return summaryChanged(id, s)
        }
        return .init(.result([:]), then: changed)
    }

    func delete(_ params: JSONValue) -> FakeHost.Answer {
        if let id = params["threadId"]?.stringValue { state.withLock { _ = $0.deleted.insert(id) } }
        return .result([:])
    }

    func fork(_ params: JSONValue) -> FakeHost.Answer {
        let source = params["threadId"]?.stringValue ?? UITestFixture.threadID
        let id = state.withLock { s in
            let id = "fixture-fork-\(s.forks.count + 1)"
            s.forks[id] = s.forks[source] ?? source
            let title = summaries(s).first { $0.threadId == source }.map { s.titles[source] ?? $0.title } ?? "Chat"
            s.started.insert(.init(threadId: id, title: title, cwd: FixtureScenario.directory,
                                   updatedAt: 1_700_000_000_003, status: .idle), at: 0)
            return id
        }
        return .result(ThreadForkResult(threadId: id))
    }

    /// A chat started from New Chat: its prompt and the quick reply, then its summary, all before
    /// the answer, which names the prompt.
    func start(_ call: FakeHost.Call) -> FakeHost.Answer {
        let params = call.params
        let (id, reply, changed) = state.withLock { s in
            let id = "fixture-new-\(s.started.count + 1)"
            s.started.insert(.init(threadId: id, title: "New Fixture Chat", cwd: FixtureScenario.directory,
                                   updatedAt: 1_700_000_000_002, status: .idle), at: 0)
            let reply = takeTurn(threadID: id, params: params, &s, FixtureReply.quick)
            return (id, reply, summaryChanged(id, s))
        }
        for message in reply.then + changed { call.link.write(message) }
        let mode = params["permissionMode"]?.stringValue.flatMap(PermissionMode.init(rawValue:)) ?? .auto
        let info = ThreadInfo(threadId: id, status: .idle, cwd: FixtureScenario.directory, appliedEffort: .medium,
                              permissionMode: mode, lastSeq: 0)
        return .result(ThreadStartResult(thread: info, messageId: reply.result.messageId))
    }

    func turn(_ params: JSONValue) -> FakeHost.Answer {
        let id = params["threadId"]?.stringValue ?? UITestFixture.threadID
        let reply = state.withLock { takeTurn(threadID: id, params: params, &$0, scenario.reply) }
        return .init(.result(json(reply.result)), then: reply.then, stream: reply.stream.isEmpty ? nil : FakeHost.Stream(reply.stream))
    }

    private func takeTurn(threadID: String, params: JSONValue, _ s: inout State,
                          _ reply: (FixturePrompt) -> FixtureReply) -> FixtureReply {
        s.nextMessage += 1
        let text = params["input"]?.arrayValue?.first?["text"]?.stringValue
        let made = reply(FixturePrompt(threadID: threadID, text: text, turn: s.nextMessage, firstSeq: s.nextSequence + 1))
        s.nextSequence += made.notificationCount
        return made
    }

    func rewind(_ params: JSONValue) -> FakeHost.Answer {
        let dryRun = params["dryRun"]?.boolValue ?? false
        let rewound = state.withLock { s in
            s.rewound += dryRun ? 0 : 1
            return s.rewound
        }
        // Once put back, there's nothing left to restore.
        let changed: JSONValue = rewound > 0 && dryRun ? []
            : ["/tmp/sundown-fixture/Sources/App.swift", "/tmp/sundown-fixture/README.md"]
        return .result(["result": ["canRewind": true, "filesChanged": changed, "insertions": 12, "deletions": 3]])
    }

    /// A host whose home (/tmp) holds no directories, above it a readable / and one that isn't.
    static func list(_ params: JSONValue) -> FakeHost.Answer {
        // "~" is the home, as the server expands it for listing (thread/start doesn't).
        let path = params["path"]?.stringValue == "~" ? "/tmp" : params["path"]?.stringValue ?? ""
        let entries: [FsListResult.Entry]? = switch path {
        case "/": [.init(name: "private", path: "/private", isDirectory: true, size: 0),
                   .init(name: "tmp", path: "/tmp", isDirectory: true, size: 0)]
        case "/tmp": [.init(name: "notes.txt", path: "/tmp/notes.txt", isDirectory: false, size: 12)]
        default: nil
        }
        guard let entries else { return .error("Permission denied: \(path)") }
        return .result(FsListResult(entries: entries))
    }

    func answered(_ id: JSONValue, _ result: JSONValue) -> [FakeHost.Message] {
        guard let answered = scenario.answered, let n = id.intValue else { return [] }
        return state.withLock { s in
            let messages = answered(n, result, s.nextSequence + 1)
            s.nextSequence += messages.filter(\.isNotification).count
            return messages
        }
    }
}
