import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// Drives a real Tether server + real `claude`. Opt in with TETHER_E2E=1; TETHER_SERVER_BIN picks
/// the server, e.g. `bun run ~/Code/tether-server/src/cli.ts` to test a working copy.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TETHER_E2E"] == "1"), .serialized)
struct LiveServerTests {
    static let server = ProcessInfo.processInfo.environment["TETHER_SERVER_BIN"]
        ?? NSString(string: "~/Code/tether-server/dist/tether-0.1.0-darwin-arm64").expandingTildeInPath

    /// A real model takes its time: minutes by default, polled gently.
    func waitUntil(_ timeout: Duration = .seconds(120),
                   fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column,
                   _ condition: () async -> Bool) async throws {
        try await eventually(timeout: timeout, interval: .milliseconds(100),
                             fileID: fileID, filePath: filePath, line: line, column: column, condition)
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

        let thread = try await conn.startThread(cwd: cwd.path, input: [], options: .init(model: "sonnet", effort: .low))
        await conn.send(thread, input: [.text(.init(text: "Write the word swift to swift.txt, then reply ok."))])
        try await waitUntil { !thread.pending.isEmpty }
        let p = try #require(thread.pending[0].request.permissionRequest)
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

        stopDaemon(home)
        await conn.disconnect()
    }

    /// A background command outlives the turn that started it and the app's connection; when the
    /// app comes back it sees the command finish as a notice, not the CLI's raw message.
    @Test func backgroundCommandFinishesWhileDisconnected() async throws {
        let (conn, home, cwd) = try await connected()
        let thread = try await conn.startThread(cwd: cwd.path, input: [], options: Self.cheap)
        await conn.send(thread, input: [.text(.init(text:
            "Run `sleep 20 && echo bg > bg.txt` with Bash in the background (run_in_background: true), then reply with just \"started\". Do not wait for it."))])
        try await waitUntil { thread.turns.count == 1 && thread.turns[0].status == .completed }

        await conn.disconnect()
        try await Task.sleep(for: .seconds(30))
        await conn.connect()

        try await waitUntil { thread.items.contains { if case .notice(let n) = $0 { n.kind == "taskNotification" } else { false } } }
        #expect(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("bg.txt").path))
        let raw = thread.items.contains { if case .userMessage(let m) = $0 { m.content.contains { if case .text(let t) = $0 { t.text.contains("<task-notification>") } else { false } } } else { false } }
        #expect(!raw)
        stopDaemon(home)
        await conn.disconnect()
    }

    /// The daemon restarts under a connected app. The thread's new stream numbers above the old
    /// one, so the app reloads instead of discarding the resumed turn's events as already seen.
    @Test func conversationContinuesAcrossADaemonRestart() async throws {
        let (conn, home, cwd) = try await connected()
        let thread = try await conn.startThread(cwd: cwd.path, input: [], options: Self.cheap)
        await conn.send(thread, input: [.text(.init(text: "Reply with just the word one."))])
        try await waitUntil { thread.turns.last?.status == .completed }

        stopDaemon(home)
        try await waitUntil(.seconds(30)) { conn.state != .connected }
        try await waitUntil(.seconds(60)) { conn.state == .connected }

        await conn.send(thread, input: [.text(.init(text: "Reply with just the word two."))])
        try await waitUntil { agentTexts(thread).contains { $0.lowercased().contains("two") } && thread.status == .idle }
        #expect(agentTexts(thread).contains { $0.lowercased().contains("one") })
        stopDaemon(home)
        await conn.disconnect()
    }

    /// A background command can be stopped from the app before it does its work.
    @Test func stoppingABackgroundCommand() async throws {
        let (conn, home, cwd) = try await connected()
        let thread = try await conn.startThread(cwd: cwd.path, input: [], options: Self.cheap)
        await conn.send(thread, input: [.text(.init(text:
            "Run `sleep 40 && echo late > late.txt` with Bash in the background (run_in_background: true), then reply with just \"started\". Do not wait for it."))])
        try await waitUntil { thread.taskEntries.contains { $0.isTaskRunning } && thread.status == .idle }
        let task = try #require(thread.taskEntries.first { $0.isTaskRunning }?.task)

        await conn.stopTask(thread, taskId: task.taskId)

        try await waitUntil(.seconds(30)) { thread.tasks[task.taskId]?.status == "stopped" }
        try await Task.sleep(for: .seconds(45))
        #expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("late.txt").path))
        stopDaemon(home)
        await conn.disconnect()
    }

    /// A foreground command holding up a turn can be sent to the background, and the turn ends
    /// while it keeps running.
    @Test func movingAForegroundCommandToTheBackground() async throws {
        let (conn, home, cwd) = try await connected()
        let thread = try await conn.startThread(cwd: cwd.path, input: [], options: Self.cheap)
        await conn.send(thread, input: [.text(.init(text:
            "Run exactly this with Bash in the foreground (not in the background): `for i in $(seq 1 40); do sleep 1; done; echo done > done.txt` — then reply with just \"ok\"."))])
        try await waitUntil { thread.taskEntries.contains { $0.isTaskRunning && $0.task?.toolUseId != nil } }
        let toolUseId = try #require(thread.taskEntries.first { $0.isTaskRunning }?.task?.toolUseId)

        await conn.moveToBackground(thread, toolUseId: toolUseId)

        // The turn ends long before the 40-second loop would have let it.
        try await waitUntil(.seconds(25)) { thread.turns.first?.status == .completed }
        #expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("done.txt").path))
        stopDaemon(home)
        await conn.disconnect()
    }

    /// The app quits mid-turn and a fresh one opens the chat: it gets the turn so far from the
    /// daemon's snapshot, then the rest live, ending with the command finished and the reply in.
    @Test func relaunchedAppPicksUpARunningTurn() async throws {
        let (first, home, cwd) = try await connected()
        let running = try await first.startThread(cwd: cwd.path, input: [], options: Self.cheap)
        await first.send(running, input: [.text(.init(text:
            "Run exactly this with Bash in the foreground: `for i in $(seq 1 15); do sleep 1; done; echo loop-done` — then reply with just \"finished\"."))])
        try await waitUntil { running.items.contains { if case .toolCall(let c) = $0 { c.status == .running } else { false } } }
        await first.disconnect()

        let relaunched = HostConnection(host: first.host)
        await relaunched.connect()
        let thread = relaunched.thread(running.id)
        await relaunched.open(thread)
        #expect(thread.historyLoaded)
        #expect(thread.turns.last?.status == .inProgress)

        try await waitUntil { thread.turns.last?.status == .completed && thread.status == .idle }
        let calls = thread.items.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(calls.allSatisfy { $0.status == .completed })
        #expect(agentTexts(thread).contains { $0.lowercased().contains("finished") })
        stopDaemon(home)
        await relaunched.disconnect()
    }

    static let cheap = NewThreadOptions(model: "sonnet", effort: .low, permissionMode: .bypassPermissions)

    private func connected() async throws -> (HostConnection, String, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tether-kit-\(UUID().uuidString.prefix(8))").path
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("tether-kit-cwd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let host = HostConfig(name: "test", kind: .local, serverCommand: "TETHER_HOME=\(home) exec \(Self.server) connect")
        let conn = HostConnection(host: host)
        await conn.connect()
        #expect(conn.state == .connected)
        return (conn, home, cwd)
    }

    private func agentTexts(_ thread: ThreadModel) -> [String] {
        thread.items.compactMap { if case .agentMessage(let m) = $0 { m.text } else { nil } }
    }

    private func stopDaemon(_ home: String) {
        if let meta = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/daemon.pid")),
           let pid = (try? JSONDecoder().decode(JSONValue.self, from: meta))?["pid"]?.intValue {
            kill(pid_t(pid), SIGTERM)
        }
    }
}
