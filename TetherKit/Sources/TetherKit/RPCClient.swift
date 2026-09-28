import Foundation
import TetherProtocol

public struct RPCError: LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public var errorDescription: String? { message }

    public static let threadNotLoaded = -32011
    public static let threadNotFound = -32010
    /// The server no longer serves this app's protocol.
    public static let incompatibleProtocol = -32004
    /// `git/removeWorktree`: the worktree has uncommitted changes; retry with `force`.
    public static let worktreeDirty = -32030
    /// `git/removeWorktree`: its branch has commits merged nowhere else; retry with `discardCommits`.
    public static let worktreeUnmerged = -32031
}

/// JSON-RPC (Codex-style, no "jsonrpc" field) over a line transport.
public actor RPCClient {
    public typealias ServerRequestHandler = @Sendable (ServerRequest) async -> JSONValue?

    private let transport: any Transport
    private var nextId = 0
    /// Each call's result as it came: the bytes of `result` in its response's line, which the call
    /// decodes into its own type.
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private let notificationsContinuation: AsyncStream<[ServerNotification]>.Continuation
    /// Notifications in the order they came, a batch at a time: streamed output waits up to
    /// `batchInterval` for the rest of its frame, and anything else goes at once, with whatever came
    /// before it. A streamed reply wakes its reader once a frame rather than once a token.
    public nonisolated let notifications: AsyncStream<[ServerNotification]>
    private var batch: [ServerNotification] = []
    private var batchFlush: Task<Void, Never>?
    private var serverRequestHandler: ServerRequestHandler?
    private var closeHandler: (@Sendable (any Error) -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let emptyObject = Data("{}".utf8)
    /// How long streamed output waits for more: about a frame.
    private let batchInterval: Duration

    public init(transport: any Transport, batchInterval: Duration = .milliseconds(16)) {
        self.transport = transport
        self.batchInterval = batchInterval
        (notifications, notificationsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func setServerRequestHandler(_ h: @escaping ServerRequestHandler) {
        serverRequestHandler = h
    }

    public func onClose(_ h: @escaping @Sendable (any Error) -> Void) {
        closeHandler = h
    }

    public func start() {
        let stream = transport.lines()
        readTask = Task { [weak self] in
            do {
                for try await line in stream { await self?.handle(line: line) }
                await self?.finish(error: TransportError.closed(exitCode: 0, stderr: ""))
            } catch {
                await self?.finish(error: error)
            }
        }
    }

    private func finish(error: any Error) {
        for (_, c) in pending { c.resume(throwing: error) }
        pending.removeAll()
        flushBatch()
        notificationsContinuation.finish()
        closeHandler?(error)
        closeHandler = nil
    }

    public func close() async {
        readTask?.cancel()
        await transport.close()
    }

    // MARK: requests

    public func call<M: TetherMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        let signpost = Signposts.rpc(M.name)
        defer { signpost.end() }
        nextId += 1
        let id = nextId
        let line = try encoder.encode(Request(id: id, method: M.name, params: params))
        let result = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await transport.send(line) } catch { self.fail(id: id, error: error) }
            }
        }
        return try decoder.decode(M.Result.self, from: result)
    }

    public func notify(_ method: String, params: JSONValue = [:]) async throws {
        let msg: JSONValue = ["method": .string(method), "params": params]
        try await transport.send(try encoder.encode(msg))
    }

    private func fail(id: Int, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// A call as it goes out, its params encoded straight from their own type.
    private struct Request<Params: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Params
    }

    // MARK: inbound

    /// Each message's members are found without decoding it, and only what's needed is decoded:
    /// params straight into the notification's or request's type, a result by the call waiting
    /// for it. Decoding the whole line to `JSONValue` and encoding its params again to decode them
    /// cost three passes over every token.
    private func handle(line: Data) {
        guard let message = WireMessage(line) else { return }
        if let method = message.method {
            if let id = message.id.flatMap({ try? decoder.decode(JSONValue.self, from: $0) }), !id.isNull {
                // Server → client request (approval, question, …): answer asynchronously.
                let params = message.params ?? Self.emptyObject
                flushBatch()
                Task { await self.answer(id: id, method: method, params: params) }
            } else if let notification = notification(method, params: message.params) {
                deliver(notification)
            }
        } else if let id = message.id.flatMap({ try? decoder.decode(JSONValue.self, from: $0) })?.intValue,
                  let cont = pending.removeValue(forKey: id) {
            // The caller sees what came before its answer.
            flushBatch()
            if let err = message.error.flatMap({ try? decoder.decode([String: JSONValue].self, from: $0) }) {
                cont.resume(throwing: RPCError(code: err["code"]?.intValue ?? -1, message: err["message"]?.stringValue ?? "error"))
            } else {
                cont.resume(returning: message.result ?? Self.emptyObject)
            }
        }
    }

    /// In its own type, or as it came when this client can't read it (a newer server's). Nil when
    /// its params aren't JSON, as a line that isn't is dropped.
    private func notification(_ method: String, params: Data?) -> ServerNotification? {
        if let n = try? ServerNotification(method: method, params: params ?? Self.emptyObject, decoder: decoder) { return n }
        guard let params else { return .unknown(method: method, params: .null) }
        return (try? decoder.decode(JSONValue.self, from: params)).map { .unknown(method: method, params: $0) }
    }

    private func deliver(_ notification: ServerNotification) {
        batch.append(notification)
        if !notification.isStreamed {
            flushBatch()
        } else if batchFlush == nil {
            batchFlush = Task { [weak self, batchInterval] in
                try? await Task.sleep(for: batchInterval)
                guard !Task.isCancelled else { return }
                await self?.flushBatch()
            }
        }
    }

    private func flushBatch() {
        batchFlush?.cancel()
        batchFlush = nil
        guard !batch.isEmpty else { return }
        notificationsContinuation.yield(batch)
        batch = []
    }

    private func answer(id: JSONValue, method: String, params: Data) async {
        let request = (try? ServerRequest(method: method, params: params, decoder: decoder))
            ?? .unknown(method: method, params: (try? decoder.decode(JSONValue.self, from: params)) ?? .null)
        let result = await serverRequestHandler?(request)
        // nil means "not answered by this client" (e.g. resolved elsewhere); send nothing.
        guard let result else { return }
        let msg: JSONValue = ["id": id, "result": result]
        if let line = try? encoder.encode(msg) { try? await transport.send(line) }
    }
}

extension ServerNotification {
    /// Output streamed as it happens (text by the token, a running tool's clock), which can wait
    /// for the rest of its frame.
    var isStreamed: Bool {
        switch self {
        case .itemAgentMessageDelta, .itemReasoningDelta, .itemToolCallInputDelta, .itemToolCallProgress: true
        default: false
        }
    }
}

/// A JSON-RPC message's top-level members, found by scanning its line rather than decoding it. Each
/// value is the bytes it came as, a slice of the line, so only what's read is ever decoded.
struct WireMessage {
    var id: Data?
    var method: String?
    var params: Data?
    var result: Data?
    var error: Data?

    enum Member: CaseIterable {
        case id, method, params, result, error

        var spelling: String {
            switch self {
            case .id: "id"
            case .method: "method"
            case .params: "params"
            case .result: "result"
            case .error: "error"
            }
        }
    }

    /// Nil when the line isn't one JSON object.
    init?(_ line: Data) {
        let found = line.withUnsafeBytes { bytes in
            var scanner = JSONScanner(bytes: bytes)
            return scanner.members()
        }
        guard let found else { return nil }
        func value(_ member: Member) -> Data? {
            found[member].map { line[(line.startIndex + $0.lowerBound)..<(line.startIndex + $0.upperBound)] }
        }
        id = value(.id)
        params = value(.params)
        result = value(.result)
        error = value(.error)
        // Not a string, as when it's absent: no method.
        method = value(.method).flatMap(JSONScanner.string)
    }
}

/// Finds a JSON object's members in its bytes, skipping over their values without decoding them:
/// a string by searching for its closing quote, a container by counting brackets outside strings.
/// Only the object's own structure is checked; a value is checked when it's decoded.
private struct JSONScanner {
    let bytes: UnsafeRawBufferPointer
    var at = 0

    /// The members `WireMessage` reads, as each value's byte range; nil when the bytes aren't one
    /// object. A repeated member takes its last value.
    mutating func members() -> [WireMessage.Member: Range<Int>]? {
        var found: [WireMessage.Member: Range<Int>] = [:]
        skipSpace()
        guard take(UInt8(ascii: "{")) else { return nil }
        skipSpace()
        if !take(UInt8(ascii: "}")) {
            repeat {
                skipSpace()
                let keyStart = at
                guard skipString() else { return nil }
                let key = keyStart..<at
                skipSpace()
                guard take(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                let valueStart = at
                guard skipValue() else { return nil }
                if let member = member(named: key) { found[member] = valueStart..<at }
                skipSpace()
            } while take(UInt8(ascii: ","))
            guard take(UInt8(ascii: "}")) else { return nil }
        }
        skipSpace()
        return at == bytes.count ? found : nil
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard at < bytes.count, bytes[at] == byte else { return false }
        at += 1
        return true
    }

    private mutating func skipSpace() {
        while at < bytes.count, Self.isSpace(bytes[at]) { at += 1 }
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09
    }

    /// Past a string, from its opening quote. A quote ends it unless an odd number of backslashes
    /// come right before it.
    private mutating func skipString() -> Bool {
        guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let base = bytes.baseAddress else { return false }
        let contentStart = at + 1
        var from = contentStart
        while from < bytes.count, let found = memchr(base + from, 0x22, bytes.count - from) {
            let quote = base.distance(to: UnsafeRawPointer(found))
            var backslashes = 0
            while quote - backslashes > contentStart, bytes[quote - backslashes - 1] == UInt8(ascii: "\\") { backslashes += 1 }
            if backslashes.isMultiple(of: 2) {
                at = quote + 1
                return true
            }
            from = quote + 1
        }
        return false
    }

    private mutating func skipValue() -> Bool {
        guard at < bytes.count else { return false }
        switch bytes[at] {
        case UInt8(ascii: "\""):
            return skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while at < bytes.count {
                switch bytes[at] {
                case UInt8(ascii: "\""):
                    guard skipString() else { return false }
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 {
                        at += 1
                        return true
                    }
                default:
                    break
                }
                at += 1
            }
            return false
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
            // A number, true, false or null: up to whatever ends it.
            while at < bytes.count {
                let b = bytes[at]
                if Self.isSpace(b) || b == UInt8(ascii: ",") || b == UInt8(ascii: "}") || b == UInt8(ascii: "]") { break }
                at += 1
            }
            return true
        default:
            return false
        }
    }

    private func member(named key: Range<Int>) -> WireMessage.Member? {
        let name = UnsafeRawBufferPointer(rebasing: bytes[(key.lowerBound + 1)..<(key.upperBound - 1)])
        if name.contains(UInt8(ascii: "\\")) {
            // Spelled with escapes: read as JSON reads it.
            guard let key = Self.string(Data(UnsafeRawBufferPointer(rebasing: bytes[key]))) else { return nil }
            return WireMessage.Member.allCases.first { $0.spelling == key }
        }
        return WireMessage.Member.allCases.first { name.elementsEqual($0.spelling.utf8) }
    }

    /// A JSON string's value; nil for anything else.
    static func string(_ value: Data) -> String? {
        value.withUnsafeBytes { bytes -> String? in
            guard bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") else { return nil }
            let content = UnsafeRawBufferPointer(rebasing: bytes[1..<(bytes.count - 1)])
            guard content.contains(UInt8(ascii: "\\")) else { return String(decoding: content, as: UTF8.self) }
            return try? JSONDecoder().decode(String.self, from: Data(bytes))
        }
    }
}
