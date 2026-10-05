import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// Once hosts install the server themselves, the app and the server can be different ages.
@MainActor
@Suite
struct ProtocolHandshakeTests {
    @Test func sendsItsProtocolAndConnects() async throws {
        let transport = HandshakeTransport(reply: .result(protocolVersion: tetherProtocolVersion))
        let connection = connection(transport)

        await connection.connect()

        #expect(connection.state == .connected)
        #expect(await transport.sentProtocolVersion == tetherProtocolVersion)
        await connection.disconnect()
    }

    @Test func aServerTooOldForTheAppSaysToUpdateItAndStopsRetrying() async throws {
        let transport = HandshakeTransport(reply: .result(protocolVersion: HostConnection.minServerProtocol - 1))
        let connection = connection(transport)

        await connection.connect()

        let message = try #require(connection.state.failure, "expected a failed connection, got \(connection.state)")
        #expect(message.contains("claude-box runs Sundown 0.4.0"))
        #expect(message.contains("Update the server"))
        #expect(connection.serverInfo == nil)
        try await Task.sleep(for: .seconds(2.5)) // past the first retry's delay
        #expect(await transport.initializeCount == 1)
    }

    @Test func aServerThatRefusesTheAppSaysTheAppNeedsUpdating() async throws {
        let transport = HandshakeTransport(reply: .refuse)
        let connection = connection(transport)

        await connection.connect()

        let message = try #require(connection.state.failure, "expected a failed connection, got \(connection.state)")
        #expect(message == "The Sundown server on claude-box needs a newer version of this app.")
        try await Task.sleep(for: .seconds(2.5))
        #expect(await transport.initializeCount == 1)
    }

    private func connection(_ transport: HandshakeTransport) -> HostConnection {
        HostConnection(
            host: HostConfig(name: "claude-box", kind: .ssh(destination: "claude-box")),
            transportProvider: { _ in transport }
        )
    }
}

/// Answers `initialize` one way and refuses everything else.
private actor HandshakeTransport: Transport {
    enum Reply: Sendable {
        case result(protocolVersion: Int)
        case refuse
    }

    private let reply: Reply
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private(set) var sentProtocolVersion: Int?
    private(set) var initializeCount = 0

    init(reply: Reply) {
        self.reply = reply
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    nonisolated func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        guard let id = message["id"] else { return }
        guard message["method"]?.stringValue == "initialize" else {
            // The catalog calls after a connection; empty handed, so connect() returns.
            let error: JSONValue = ["code": -32601, "message": "not scripted"]
            continuation.yield(try JSONEncoder().encode(["id": id, "error": error] as JSONValue))
            return
        }
        initializeCount += 1
        sentProtocolVersion = message["params"]?["protocolVersion"]?.intValue
        let response: JSONValue
        switch reply {
        case .result(let version):
            let result = InitializeResult(
                serverInfo: .init(name: "tether", version: "0.4.0"),
                protocolVersion: version,
                minClientProtocol: 1,
                host: .init(hostname: "claude-box", platform: "linux", arch: "arm64", home: "/home/dev", pid: 1, mode: .daemon),
                claude: .init(path: "/usr/bin/claude", version: "test"))
            response = ["id": id, "result": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))]
        case .refuse:
            response = ["id": id, "error": [
                "code": .number(Double(RPCError.incompatibleProtocol)),
                "message": "This client speaks protocol 1; tether 0.9.0 needs 2 or later",
                "data": ["protocolVersion": 2, "minClientProtocol": 2],
            ]]
        }
        continuation.yield(try JSONEncoder().encode(response))
    }

    func close() async { continuation.finish() }
}
