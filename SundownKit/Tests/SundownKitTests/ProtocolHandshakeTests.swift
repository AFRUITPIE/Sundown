import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownFixtures
import SundownTestSupport

/// Once hosts install the server themselves, the app and the server can be different ages.
@MainActor
@Suite
struct ProtocolHandshakeTests {
    @Test func sendsItsProtocolAndConnects() async throws {
        let host = server(protocolVersion: tetherProtocolVersion)
        let connection = connection(host)

        await connection.connect()

        #expect(connection.state == .connected)
        #expect(host.calls(of: "initialize").first?["protocolVersion"]?.intValue == tetherProtocolVersion)
        await connection.disconnect()
    }

    @Test func aServerTooOldForTheAppSaysToUpdateItAndStopsRetrying() async throws {
        let host = server(protocolVersion: HostConnection.minServerProtocol - 1)
        let connection = connection(host)

        await connection.connect()

        let message = try #require(connection.state.failure, "expected a failed connection, got \(connection.state)")
        #expect(message.contains("claude-box runs Sundown 0.4.0"))
        #expect(message.contains("Update the server"))
        #expect(connection.serverInfo == nil)
        try await Task.sleep(for: .seconds(2.5)) // past the first retry's delay
        #expect(host.count("initialize") == 1)
    }

    @Test func aServerThatRefusesTheAppSaysTheAppNeedsUpdating() async throws {
        let host = FakeHost(hostname: "claude-box")
        host.fail("initialize", code: RPCError.incompatibleProtocol,
                  "This client speaks protocol 1; tether 0.9.0 needs 2 or later",
                  data: ["protocolVersion": 2, "minClientProtocol": 2])
        let connection = connection(host)

        await connection.connect()

        let message = try #require(connection.state.failure, "expected a failed connection, got \(connection.state)")
        #expect(message == "The Sundown server on claude-box needs a newer version of this app.")
        try await Task.sleep(for: .seconds(2.5))
        #expect(host.count("initialize") == 1)
    }

    /// Sundown 0.4.0 on claude-box, speaking `protocolVersion`.
    private func server(protocolVersion: Int) -> FakeHost {
        let host = FakeHost(hostname: "claude-box")
        var result = host.initializeResult
        result.serverInfo = .init(name: "tether", version: "0.4.0")
        result.protocolVersion = protocolVersion
        result.minClientProtocol = 1
        host.initializeResult = result
        return host
    }

    private func connection(_ host: FakeHost) -> HostConnection {
        host.connection(host: HostConfig(name: "claude-box", kind: .ssh(destination: "claude-box")))
    }
}
