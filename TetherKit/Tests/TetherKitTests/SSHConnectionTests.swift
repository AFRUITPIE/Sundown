import Foundation
import Testing
@testable import TetherKit

/// Exercises the same bootstrap, transport, and protocol handshake as the app without starting a
/// chat. Opt in explicitly so ordinary unit-test runs never touch a remote machine.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TETHER_SSH_E2E"] == "1"), .serialized)
struct SSHConnectionTests {
    @Test(.timeLimit(.minutes(2)))
    func bootstrapHandshakeAndReconnectWithoutStartingAClaudeTurn() async {
        let destination = ProcessInfo.processInfo.environment["TETHER_SSH_DESTINATION"] ?? "claude-box"
        let connection = HostConnection(host: HostConfig(
            name: "SSH smoke test",
            kind: .ssh(destination: destination)
        ))

        await connection.connect()

        #expect(connection.state == .connected)
        #expect(connection.serverInfo?.host.hostname.isEmpty == false)
        #expect(connection.serverInfo?.claude.path.isEmpty == false)
        await connection.disconnect()
        #expect(connection.state == .disconnected)

        await connection.connect()
        #expect(connection.state == .connected)
        #expect(connection.serverInfo?.host.hostname.isEmpty == false)
        await connection.disconnect()
    }

    /// Reattaches to an existing remote turn without sending input. Set the ID of a session that
    /// is currently running on the SSH host to exercise the real follower/replay path.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TETHER_SSH_REATTACH_THREAD_ID"] != nil),
        .timeLimit(.minutes(2))
    )
    func reattachToConfiguredLongRunningSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        let destination = environment["TETHER_SSH_DESTINATION"] ?? "claude-box"
        let threadID = try #require(environment["TETHER_SSH_REATTACH_THREAD_ID"])
        let connection = HostConnection(host: HostConfig(
            name: "SSH reattach test",
            kind: .ssh(destination: destination)
        ))

        await connection.connect()
        let thread = try #require(connection.chats.first { $0.id == threadID })
        await connection.open(thread)
        #expect(thread.historyLoaded)
        let identity = ObjectIdentifier(thread)
        let sequenceBeforeDisconnect = thread.lastSeq

        await connection.disconnect()
        await connection.connect()

        #expect(ObjectIdentifier(connection.thread(threadID)) == identity)
        #expect(thread.lastSeq >= sequenceBeforeDisconnect)
        #expect(thread.lastError == nil)
        await connection.disconnect()
    }
}
