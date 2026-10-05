import Foundation
import TetherProtocol
@testable import SundownKit

/// A daemon for `HostConnection` tests: answers each method with the replies queued for it (the
/// last one again once the queue runs down), records what it was asked, and sends notifications
/// when told.
final class FakeDaemon: Transport, @unchecked Sendable {
    let script = DaemonScript()
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    /// A connection to this daemon.
    @MainActor
    func connection() -> HostConnection {
        HostConnection(host: HostConfig(name: "Fake", kind: .ssh(destination: "fake")), transportProvider: { _ in self })
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        let response: JSONValue = if let result = await script.reply(method, message["params"] ?? [:]) {
            ["id": id, "result": result]
        } else {
            ["id": id, "error": ["code": -32601, "message": .string("Not in the script: \(method)")]]
        }
        continuation.yield(try JSONEncoder().encode(response))
    }

    func close() async { continuation.finish() }

    func emit(_ method: String, _ params: JSONValue) {
        continuation.yield(try! JSONEncoder().encode(["method": .string(method), "params": params] as JSONValue))
    }
}

actor DaemonScript {
    private var replies: [String: [JSONValue]] = [:]
    /// Methods whose last reply has been given, and is given again until another is queued.
    private var repeating = Set<String>()
    private(set) var calls: [(method: String, params: JSONValue)] = []
    /// Methods whose replies wait for `release(_:)`.
    private var held = Set<String>()
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func hold(_ method: String) { held.insert(method) }

    func release(_ method: String) {
        held.remove(method)
        for waiter in waiting.removeValue(forKey: method) ?? [] { waiter.resume() }
    }

    func queue<Result: Encodable & Sendable>(_ method: String, _ results: Result...) {
        if repeating.remove(method) != nil { replies[method] = [] }
        replies[method, default: []] += results.map(encoded)
    }

    func params(of method: String) -> [JSONValue] { calls.filter { $0.method == method }.map(\.params) }

    func reply(_ method: String, _ params: JSONValue) async -> JSONValue? {
        calls.append((method, params))
        if held.contains(method) { await withCheckedContinuation { waiting[method, default: []].append($0) } }
        if var queued = replies[method], !queued.isEmpty {
            guard queued.count > 1 else {
                repeating.insert(method)
                return queued[0]
            }
            let next = queued.removeFirst()
            replies[method] = queued
            return next
        }
        switch method {
        case "initialize":
            return encoded(InitializeResult(
                serverInfo: .init(name: "tether-server", version: "test"), protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "fake", platform: "linux", arch: "arm64", home: "/home/dev", pid: 1, mode: .daemon),
                claude: .init(path: "/usr/bin/claude", version: "test")))
        case "thread/unsubscribe": return [:]
        case "project/list": return ["projects": []]
        case "model/list": return ["models": []]
        case "thread/list": return ["threads": []]
        default: return nil
        }
    }
}

func encoded(_ value: some Encodable) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
