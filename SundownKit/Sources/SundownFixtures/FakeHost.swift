import Foundation
import Synchronization
import SundownKit
import TetherProtocol

/// A Sundown daemon in memory: the one fake host the package's tests, the UI-test fixture and the
/// benchmarks talk to. Each `connect()` is a new connection (`Link`) to the same daemon, which
/// answers `initialize` and the catalog by itself, each other method as it's told (`answer`,
/// `queue`, `once`, `fail`, or a scenario's chats, `serve`), can hold a method's answers until
/// released, records every call and every line the client sent, and sends notifications, requests
/// and raw lines down its latest connection, or drops it.
///
/// In every build, as the UI-test fixture is: the performance tests run against Release.
public final class FakeHost: Sendable {
    /// A call the client made.
    public struct Call: Sendable {
        public let method: String
        public let params: JSONValue
        public let id: JSONValue
        /// The connection it came on, counting from 1.
        public let connection: Int
        let link: Link

        /// Sends a notification on the call's connection before its answer, as a daemon sends the
        /// prompt's echo before `thread/start`'s answer.
        public func emit(_ method: String, _ params: JSONValue) { link.write(.notification(method, params)) }
    }

    /// What a call is answered with, and what follows the answer.
    public struct Answer: Sendable {
        public enum Outcome: Sendable {
            case result(JSONValue)
            case error(code: Int, message: String, data: JSONValue?)
        }

        public var outcome: Outcome
        /// Sent right after the answer: notifications, and requests of the host's own.
        public var then: [Message] = []
        /// Sent after those, paced as a host streams a reply.
        public var stream: Stream?

        public init(_ outcome: Outcome, then: [Message] = [], stream: Stream? = nil) {
            self.outcome = outcome
            self.then = then
            self.stream = stream
        }

        public static func result(_ value: JSONValue) -> Answer { .init(.result(value)) }
        public static func result(_ value: some Encodable) -> Answer { .init(.result(json(value))) }
        public static func error(code: Int = -32601, _ message: String, data: JSONValue? = nil) -> Answer {
            .init(.error(code: code, message: message, data: data))
        }
    }

    /// A line the host sends that isn't an answer.
    public enum Message: Sendable {
        case notification(String, JSONValue)
        /// A request of the host's own (a permission, a question), which the client answers by `id`.
        case request(id: JSONValue, String, JSONValue)
        /// In a stream, a frame in which nothing is sent.
        case pause

        var json: JSONValue? {
            switch self {
            case .notification(let method, let params): ["method": .string(method), "params": params]
            case .request(let id, let method, let params): ["id": id, "method": .string(method), "params": params]
            case .pause: nil
            }
        }

        var isNotification: Bool { if case .notification = self { true } else { false } }
    }

    /// Messages sent one a frame, after a moment's thought, as a host streams a reply.
    public struct Stream: Sendable {
        public var messages: [Message]
        public var delay: Duration
        public var interval: Duration

        public init(_ messages: [Message], delay: Duration = .milliseconds(300), interval: Duration = .milliseconds(16)) {
            self.messages = messages
            self.delay = delay
            self.interval = interval
        }
    }

    public typealias Responder = @Sendable (Call) async -> Answer
    /// What the host makes of the client's answer to one of its requests: what it sends next.
    public typealias AnswerHandler = @Sendable (_ id: JSONValue, _ result: JSONValue) -> [Message]

    private struct Queued: Sendable {
        let responder: Responder
        /// Given again, as the standing answer, once it's the last one queued.
        let stays: Bool
    }

    private struct State: Sendable {
        var initialize: InitializeResult
        var standing: [String: Responder] = [:]
        var queued: [String: [Queued]] = [:]
        var held: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var whenAnswered: AnswerHandler?
        var calls: [Call] = []
        var taken = 0
        var received: [JSONValue] = []
        var links: [Link] = []
        var connects = 0
        var refusesConnections = false
    }

    private let state: Mutex<State>
    private let unscripted: String

    /// A host answering `initialize` as `hostname` (process `pid`), with no models and no chats.
    /// A method nothing answers is an error saying `unscripted` and the method.
    public init(hostname: String = "fake", pid: Int = 1, unscripted: String = "Not in the script") {
        state = Mutex(State(initialize: InitializeResult(
            serverInfo: .init(name: "tether-server", version: "test"), protocolVersion: tetherProtocolVersion,
            host: .init(hostname: hostname, platform: "linux", arch: "arm64", home: "/home/dev", pid: pid, mode: .daemon),
            claude: .init(path: "/usr/bin/claude", version: "test"))))
        self.unscripted = unscripted
    }

    // MARK: Connections

    /// One connection to the daemon.
    public final class Link: Transport, Sendable {
        public let number: Int
        private let host: FakeHost
        private let stream: AsyncThrowingStream<Data, any Error>
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

        fileprivate init(host: FakeHost, number: Int) {
            self.host = host
            self.number = number
            (stream, continuation) = AsyncThrowingStream.makeStream()
        }

        public func lines() -> AsyncThrowingStream<Data, any Error> { stream }
        public func send(_ line: Data) async throws { try await host.receive(line, on: self) }
        public func close() async { continuation.finish() }

        func write(_ message: Message) {
            if let value = message.json { write(value) }
        }

        func write(_ value: JSONValue) {
            continuation.yield(try! JSONEncoder().encode(value))
        }

        func write(line: Data) { continuation.yield(line) }
        /// The connection drops, as when the daemon or the network goes away.
        func drop() { continuation.finish(throwing: TransportError.launchFailed("Dropped")) }
        /// The host hangs up after what it has sent.
        func hangUp() { continuation.finish() }
    }

    /// A new connection, or a failure while connections are refused.
    public func connect() throws -> Link {
        try state.withLock { s in
            s.connects += 1
            if s.refusesConnections { throw TransportError.launchFailed("The fake host refuses connections") }
            let link = Link(host: self, number: s.links.count + 1)
            s.links.append(link)
            return link
        }
    }

    /// Connections made, refused ones included.
    public var connects: Int { state.withLock { $0.connects } }

    public var refusesConnections: Bool {
        get { state.withLock { $0.refusesConnections } }
        set { state.withLock { $0.refusesConnections = newValue } }
    }

    /// The daemon's process, which `initialize` reports: a new one says the daemon restarted.
    public var pid: Int {
        get { state.withLock { $0.initialize.host.pid } }
        set { state.withLock { $0.initialize.host.pid = newValue } }
    }

    /// What `initialize` answers, unless something else is told to.
    public var initializeResult: InitializeResult {
        get { state.withLock { $0.initialize } }
        set { state.withLock { $0.initialize = newValue } }
    }

    /// The latest connection.
    public var link: Link? { state.withLock { $0.links.last } }

    /// A `HostConnection` whose every connection is one to this host.
    @MainActor
    public func connection(host: HostConfig = HostConfig(name: "Fake", kind: .ssh(destination: "fake")),
                           network: NetworkPath? = nil) -> HostConnection {
        HostConnection(host: host, network: network, transportProvider: { _ in try self.connect() })
    }

    /// A `HostConnection` that connects to each of `hosts` in turn, as a daemon that restarts
    /// between connections, and is refused once they've all been used.
    @MainActor
    public static func connection(to hosts: [FakeHost],
                                  host: HostConfig = HostConfig(name: "Fake", kind: .ssh(destination: "fake"))) -> HostConnection {
        let next = Mutex(0)
        return HostConnection(host: host, transportProvider: { _ in
            let index = next.withLock { n in defer { n += 1 }; return n }
            guard index < hosts.count else { throw TransportError.launchFailed("No more hosts") }
            return try hosts[index].connect()
        })
    }

    // MARK: Answers

    /// `method`'s standing answer, given whenever nothing is queued for it.
    public func answer(_ method: String, _ responder: @escaping Responder) {
        state.withLock { $0.standing[method] = responder }
    }

    public func answer(_ method: String, _ answer: Answer) {
        self.answer(method) { _ in answer }
    }

    public func answer(_ method: String, with result: some Encodable & Sendable) {
        answer(method, .result(json(result)))
    }

    /// `method` fails, as the daemon answers with an error.
    public func fail(_ method: String, code: Int = -32601, _ message: String, data: JSONValue? = nil) {
        answer(method, .error(code: code, message, data: data))
    }

    /// Answers `method` with each of `results` in turn, the last of them again until another is
    /// queued.
    public func queue<Result: Encodable & Sendable>(_ method: String, _ results: Result...) {
        let answers = results.map { result in Answer.result(json(result)) }
        state.withLock { s in
            for (i, answer) in answers.enumerated() {
                s.queued[method, default: []].append(Queued(responder: { _ in answer }, stays: i == answers.count - 1))
            }
        }
    }

    /// Answers `method`'s next call so, once, before its standing answer.
    public func once(_ method: String, _ answer: Answer) {
        state.withLock { $0.queued[method, default: []].append(Queued(responder: { _ in answer }, stays: false)) }
    }

    public func once(_ method: String, with result: some Encodable & Sendable) {
        once(method, .result(json(result)))
    }

    /// `method`'s answers wait until `release(_:)`.
    public func hold(_ method: String) {
        state.withLock { _ = $0.held.insert(method) }
    }

    public func release(_ method: String) {
        let waiters = state.withLock { s in
            s.held.remove(method)
            return s.waiting.removeValue(forKey: method) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }

    /// What the host does with the client's answers to its requests.
    public func whenAnswered(_ handler: @escaping AnswerHandler) {
        state.withLock { $0.whenAnswered = handler }
    }

    // MARK: What the client sent

    public var calls: [Call] { state.withLock { $0.calls } }

    /// The params of each call of `method`, on `connection` if one is named.
    public func calls(of method: String, onConnection connection: Int? = nil) -> [JSONValue] {
        state.withLock { s in
            s.calls.filter { $0.method == method && (connection == nil || $0.connection == connection) }.map(\.params)
        }
    }

    public func count(_ method: String) -> Int { calls(of: method).count }

    /// The methods called since the last time this was asked.
    public func takeMethods() -> [String] {
        state.withLock { s in
            defer { s.taken = s.calls.count }
            return s.calls[s.taken...].map(\.method)
        }
    }

    /// Forgets the calls made so far.
    public func forgetCalls() {
        state.withLock { s in
            s.calls = []
            s.taken = 0
        }
    }

    /// Every message the client sent, its answers to the host's requests included.
    public var received: [JSONValue] { state.withLock { $0.received } }

    // MARK: Sending, on the latest connection

    public func emit(_ method: String, _ params: JSONValue) { link?.write(.notification(method, params)) }
    /// A whole message: a notification, or a request with an id.
    public func emit(message: JSONValue) { link?.write(message) }
    /// A line as it is, whatever it holds.
    public func emit(line: String) { link?.write(line: Data(line.utf8)) }
    /// The latest connection drops, as when the daemon or the network goes away.
    public func drop() { link?.drop() }
    /// The latest connection ends after what was sent on it.
    public func hangUp() { link?.hangUp() }

    // MARK: Answering

    fileprivate func receive(_ line: Data, on link: Link) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        state.withLock { $0.received.append(message) }
        guard let id = message["id"] else { return }
        guard let method = message["method"]?.stringValue else {
            let handler = state.withLock { $0.whenAnswered }
            for next in handler?(id, message["result"] ?? message["error"] ?? .null) ?? [] { link.write(next) }
            return
        }
        let call = Call(method: method, params: message["params"] ?? [:], id: id, connection: link.number, link: link)
        state.withLock { $0.calls.append(call) }
        await waitWhileHeld(method)
        let answer = await responder(for: method)(call)
        switch answer.outcome {
        case .result(let result):
            link.write(["id": id, "result": result])
        case .error(let code, let text, let data):
            var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(text)]
            if let data { error["data"] = data }
            link.write(["id": id, "error": .object(error)])
        }
        for next in answer.then { link.write(next) }
        if let stream = answer.stream, !stream.messages.isEmpty {
            Task {
                try? await Task.sleep(for: stream.delay)
                for next in stream.messages {
                    link.write(next)
                    try? await Task.sleep(for: stream.interval)
                }
            }
        }
    }

    private func waitWhileHeld(_ method: String) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let held = state.withLock { s in
                guard s.held.contains(method) else { return false }
                s.waiting[method, default: []].append(waiter)
                return true
            }
            if !held { waiter.resume() }
        }
    }

    private func responder(for method: String) -> Responder {
        state.withLock { s in
            if var queue = s.queued[method], !queue.isEmpty {
                let next = queue.removeFirst()
                s.queued[method] = queue
                if queue.isEmpty, next.stays { s.standing[method] = next.responder }
                return next.responder
            }
            if let standing = s.standing[method] { return standing }
            let initialize = s.initialize
            switch method {
            case "initialize": return { _ in .result(initialize) }
            case "model/list": return { _ in .result(["models": []]) }
            case "thread/list": return { _ in .result(["threads": []]) }
            case "thread/unsubscribe": return { _ in .result([:]) }
            default:
                let text = "\(unscripted): \(method)"
                return { _ in .error(text) }
            }
        }
    }
}

/// `value` as the JSON the wire carries.
public func json(_ value: some Encodable) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
