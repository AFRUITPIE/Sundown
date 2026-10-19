import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownFixtures

/// The Changes pane's working tree is one `git/changes` call, its lines numbered here for comments.
@MainActor
@Suite
struct WorkingChangesTests {
    private let edited = WorkingFileChange(path: "Sources/App.swift", status: .modified, hunks: [
        DiffHunk(oldStart: 10, oldLines: 3, newStart: 10, newLines: 4,
                 lines: [" a", "-b", "+B", "+C", " d", "\\ No newline at end of file"], header: "func body()"),
    ], added: 2, removed: 1, truncatedLines: 0)

    /// Each line takes its number on the side it's on, from where its hunk starts; "No newline at
    /// end of file" isn't a line.
    @Test func linesAreNumberedFromTheirHunk() throws {
        let file = FileDiff(edited)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -10,3 +10,4 @@ func body()")
        #expect(hunk.lines.map(\.text) == ["a", "b", "B", "C", "d"])
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(hunk.lines.map(\.oldNumber) == [10, 11, nil, nil, 12])
        #expect(hunk.lines.map(\.newNumber) == [10, nil, 11, 12, 13])
        #expect(file.lineCount == 5)
        #expect(file.added == 2 && file.removed == 1)
    }

    /// One call, and what it says: the repository's top, the branch as git's header names it, and
    /// the new files the daemon left uncounted.
    @Test func oneCallReadsTheWorkingTree() async throws {
        let host = FakeHost(hostname: "git-box")
        host.answer("git/changes") { [edited] call in
            let inRepo = call.params["cwd"]?.stringValue == "/work/project/Sources"
            return .result(GitChangesResult(isRepo: inRepo, root: inRepo ? "/work/project" : nil,
                                            branch: inRepo ? "No commits yet on main" : nil,
                                            files: inRepo ? [edited] : [], omittedFiles: inRepo ? 50 : 0))
        }
        let connection = host.connection(host: HostConfig(name: "Git fixture", kind: .ssh(destination: "git-box")))
        await connection.connect()
        let changes = try #require(try await connection.workingChanges(cwd: "/work/project/Sources"))
        #expect(changes.root == "/work/project")
        #expect(changes.branch == "main")
        #expect(changes.files.map(\.path) == ["Sources/App.swift"])
        #expect(changes.omittedFiles == 50)
        #expect(changes.added == 2 && changes.removed == 1)
        #expect(try await connection.workingChanges(cwd: "/tmp") == nil)
        #expect(host.calls.map(\.method).filter { $0.hasPrefix("git/") || $0.hasPrefix("fs/") } == ["git/changes", "git/changes"])
        await connection.disconnect()
    }
}
