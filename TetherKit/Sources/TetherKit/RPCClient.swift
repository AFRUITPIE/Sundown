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
}

/// JSON-RPC (Codex-style, no "jsonrpc" field) over a line transport.
public actor RPCClient {
    public typealias ServerRequestHandler = @Sendable (ServerRequest) async -> JSONValue?

    private let transport: any Transport
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private let notificationsContinuation: AsyncStream<ServerNotification>.Continuation
    public nonisolated let notifications: AsyncStream<ServerNotification>
    private var serverRequestHandler: ServerRequestHandler?
    private var closeHandler: (@Sendable (any Error) -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: any Transport) {
        self.transport = transport
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
        let data = try await rawCall(M.name, params: try encoder.encode(params))
        return try decoder.decode(M.Result.self, from: data)
    }

    public func notify(_ method: String, params: JSONValue = [:]) async throws {
        let msg: JSONValue = ["method": .string(method), "params": params]
        try await transport.send(try encoder.encode(msg))
    }

    private func rawCall(_ method: String, params: Data) async throws -> Data {
        nextId += 1
        let id = nextId
        let paramsValue = try decoder.decode(JSONValue.self, from: params)
        let msg: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": paramsValue]
        let line = try encoder.encode(msg)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await transport.send(line) } catch { self.fail(id: id, error: error) }
            }
        }
    }

    private func fail(id: Int, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: inbound

    private func handle(line: Data) async {
        guard let msg = try? decoder.decode(JSONValue.self, from: line), let obj = msg.objectValue else { return }
        let method = obj["method"]?.stringValue
        let id = obj["id"]
        if let method, let id, !id.isNull {
            // Server → client request (approval, question, …): answer asynchronously.
            let params = (try? encoder.encode(obj["params"] ?? [:])) ?? Data("{}".utf8)
            Task { await self.answer(id: id, method: method, params: params) }
        } else if let method {
            let params = (try? encoder.encode(obj["params"] ?? [:])) ?? Data("{}".utf8)
            do {
                notificationsContinuation.yield(try ServerNotification(method: method, params: params, decoder: decoder))
            } catch {
                notificationsContinuation.yield(.unknown(method: method, params: obj["params"] ?? .null))
            }
        } else if let idNum = id?.intValue, let cont = pending.removeValue(forKey: idNum) {
            if let err = obj["error"]?.objectValue {
                cont.resume(throwing: RPCError(code: err["code"]?.intValue ?? -1, message: err["message"]?.stringValue ?? "error"))
            } else {
                cont.resume(returning: (try? encoder.encode(obj["result"] ?? [:])) ?? Data("{}".utf8))
            }
        }
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
