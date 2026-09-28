import Foundation
import Testing
import TetherProtocol
@testable import TetherKit
@testable import TetherUI

/// How many requests the common actions send the host: each is a round trip, over SSH a slow one,
/// and the daemon's work. The budgets are today's counts, as ceilings. When a change sends fewer,
/// lower its budget here so the saving stays; when one sends more, say why beside the budget.
///
/// A switch is what the window model and the views showing the chat ask for together; the views'
/// part is done by hand below, one line per view. A view that stops asking (the composer no longer
/// listing commands on every switch, say) loses its line, and the budget comes down with it.
@MainActor
@Suite
struct RPCBudgetTests {
    /// initialize, then the catalog: project/list, model/list, account/read, thread/list.
    static let connecting = 5
    /// thread/read and thread/subscribe (ThreadView), command/list (Composer).
    static let openingAChat = 3
    /// The same for the chat switched to, and thread/unsubscribe for the one left: a chat the
    /// daemon isn't running is let go when no window shows it.
    static let switchingChats = 4

    @Test func openingAndSwitchingChatsStayWithinBudget() async throws {
        let host = CountingHost()
        let connection = HostConnection(host: HostConfig(name: "Budget", kind: .ssh(destination: "budget.invalid")),
                                        transportProvider: { _ in host })
        await connection.connect()
        let connect = host.take()
        #expect(connect.count <= Self.connecting, "connecting: \(connect)")

        let window = WindowModel(app: .sample(connections: [connection]), target: WindowTarget(hostID: connection.id))
        window.start()
        #expect(host.take().isEmpty, "a window on New Chat asks for nothing")

        // Shows a chat as a window does: the selection, then what the views showing it ask for.
        func show(_ id: String) async throws -> [String] {
            window.threadID = id
            let thread = try #require(window.selectedThread)
            await connection.open(thread) // ThreadView's task
            _ = await connection.commands(cwd: thread.cwd, thread: thread) // Composer's task
            // Letting the last chat go is a request of its own, sent without waiting for it.
            try await Task.sleep(for: .milliseconds(50))
            return host.take()
        }

        let open = try await show("chat-a")
        #expect(open.count <= Self.openingAChat, "opening a chat: \(open)")
        let switched = try await show("chat-b")
        #expect(switched.count <= Self.switchingChats, "switching chats: \(switched)")
        let back = try await show("chat-a")
        #expect(back.count <= Self.switchingChats, "switching back: \(back)")
        await connection.disconnect()
    }
}

/// A host with two idle chats it isn't running, which answers what connecting, opening and switching
/// ask, and counts the requests.
private final class CountingHost: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    /// The requests since the last call.
    func take() -> [String] {
        lock.withLock { defer { methods = [] }; return methods }
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        lock.withLock { methods.append(method) }
        let reply: JSONValue = if let result = Self.result(method, message["params"] ?? [:]) {
            ["id": id, "result": result]
        } else {
            ["id": id, "error": ["code": -32601, "message": .string("Not in the budget host: \(method)")]]
        }
        continuation.yield(try JSONEncoder().encode(reply))
    }

    func close() async { continuation.finish() }

    private static func result(_ method: String, _ params: JSONValue) -> JSONValue? {
        let thread = params["threadId"]?.stringValue ?? "chat-a"
        switch method {
        case "initialize":
            return json(InitializeResult(
                serverInfo: .init(name: "tether-server", version: "test"), protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "budget", platform: "linux", arch: "arm64", home: "/home/dev", pid: 1, mode: .daemon),
                claude: .init(path: "/usr/bin/claude", version: "test")))
        case "project/list": return ["projects": []]
        case "model/list": return ["models": []]
        case "thread/list":
            return json(ThreadListResult(threads: ["chat-a", "chat-b"].map {
                .init(threadId: $0, title: $0, cwd: "/work/project", updatedAt: 1, status: .idle)
            }))
        case "thread/read":
            return json(ThreadReadResult(items: [.agentMessage(.init(id: "\(thread)-answer", createdAt: 1, text: "An answer."))],
                                         turns: [], historySeq: 5, hasMore: false))
        case "thread/subscribe":
            return json(ThreadSubscribeResult(thread: .init(threadId: thread, status: .notLoaded, cwd: "/work/project", lastSeq: 5),
                                              replayed: 0, gap: false))
        case "thread/unsubscribe": return [:]
        case "command/list": return ["commands": []]
        default: return nil
        }
    }
}

private func json<T: Encodable>(_ value: T) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
