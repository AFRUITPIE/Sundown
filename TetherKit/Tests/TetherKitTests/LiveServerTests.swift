import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// Drives a real Tether server + real `claude` (haiku). Opt in with TETHER_E2E=1.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TETHER_E2E"] == "1"), .serialized)
struct LiveServerTests {
    static let server = ProcessInfo.processInfo.environment["TETHER_SERVER_BIN"]
        ?? NSString(string: "~/Code/tether-server/dist/tether-0.1.0-darwin-arm64").expandingTildeInPath

    func waitUntil(_ timeout: Duration = .seconds(120), _ cond: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond() {
            if ContinuousClock.now > deadline { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func startSendApproveAndReconnect() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tether-kit-\(UUID().uuidString.prefix(8))").path
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("tether-kit-cwd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let host = HostConfig(name: "test", kind: .local, serverCommand: "TETHER_HOME=\(home) exec \(Self.server) connect")
        let conn = HostConnection(host: host)
        await conn.connect()
        #expect(conn.state == .connected)
        #expect(conn.serverInfo?.host.mode == "daemon")
        try await waitUntil { !conn.models.isEmpty }

        let thread = try await conn.startThread(cwd: cwd.path, input: [], options: .init(model: "haiku"))
        await conn.send(thread, input: [.text(.init(text: "Write the word swift to swift.txt, then reply ok."))])
        try await waitUntil { !thread.pending.isEmpty }
        guard case .permissionRequest(let p) = thread.pending[0].request else { Issue.record("expected permission"); return }
        #expect(p.toolName == "Write")

        // Drop the connection while the approval is pending; the daemon parks it.
        await conn.disconnect()
        #expect(thread.pending.isEmpty)
        await conn.connect()
        try await waitUntil { !thread.pending.isEmpty }
        thread.answer(thread.pending[0], with: ["decision": "allow"])
        try await waitUntil { thread.turns.last?.status == .completed }
        #expect(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("swift.txt").path))
        let texts = thread.items.compactMap { if case .agentMessage(let m) = $0 { m.text } else { nil } }
        #expect(!texts.isEmpty)
        #expect(thread.status == .idle)

        // Stop the test daemon.
        if let meta = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/daemon.pid")),
           let pid = (try? JSONDecoder().decode(JSONValue.self, from: meta))?["pid"]?.intValue {
            kill(pid_t(pid), SIGTERM)
        }
        await conn.disconnect()
    }
}
