import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// The Changes pane's new files are read a few at a time, and only so many.
@MainActor
@Suite
struct WorkingChangesTests {
    @Test func newFilesAreReadEightAtATimeAndCapped() async throws {
        let script = GitScript(untracked: WorkingChanges.maxUntrackedFiles + 50)
        let connection = HostConnection(host: HostConfig(name: "Git fixture", kind: .ssh(destination: "git-box")),
                                        transportProvider: { _ in ScriptedTransport { method, _ in await script.reply(method: method) } })
        await connection.connect()
        let changes = try #require(try await connection.workingChanges(cwd: "/work/project"))
        #expect(changes.files.count == WorkingChanges.maxUntrackedFiles)
        #expect(changes.omittedFiles == 50)
        #expect(changes.files.map(\.path) == changes.files.map(\.path).sorted())
        #expect(changes.files.allSatisfy { $0.added == 1 })
        let reads = await script.readCounts()
        #expect(reads.total == WorkingChanges.maxUntrackedFiles)
        #expect(reads.mostAtOnce > 1 && reads.mostAtOnce <= 8)
        await connection.disconnect()
    }
}

private actor GitScript {
    let untracked: Int
    private var reading = 0
    private var mostAtOnce = 0
    private var total = 0

    init(untracked: Int) { self.untracked = untracked }

    func readCounts() -> (total: Int, mostAtOnce: Int) { (total, mostAtOnce) }

    func startRead() {
        reading += 1
        total += 1
        mostAtOnce = max(mostAtOnce, reading)
    }

    func endRead() { reading -= 1 }

    func reply(method: String) async -> ScriptedReply {
        if method == "fs/read" {
            // Answered a moment later, as a host does, so reads can overlap.
            startRead()
            try? await Task.sleep(for: .milliseconds(2))
            endRead()
            return .result(["content": "one line\n", "encoding": "utf-8", "truncated": false])
        }
        guard let result = result(method: method) else { return .error(code: -32601, message: "Not implemented in fixture") }
        return .result(result)
    }

    private func result(method: String) -> JSONValue? {
        switch method {
        case "initialize":
            return encoded(InitializeResult(
                serverInfo: .init(name: "tether-server", version: "test"),
                protocolVersion: tetherProtocolVersion,
                host: .init(hostname: "git-box", platform: "linux", arch: "arm64", home: "/home/dev", pid: 1, mode: .daemon),
                claude: .init(path: "/usr/bin/claude", version: "test")
            ))
        case "project/list": return ["projects": []]
        case "model/list": return ["models": []]
        case "thread/list": return ["threads": []]
        case "git/status":
            let files = (0..<untracked).map { i -> JSONValue in ["status": "??", "path": .string(String(format: "new/file%03d.txt", i))] }
            return ["isRepo": true, "branch": "main", "files": .array(files + [["status": "??", "path": "build/"]])]
        case "git/diff": return ["diff": ""]
        default: return nil
        }
    }
}
