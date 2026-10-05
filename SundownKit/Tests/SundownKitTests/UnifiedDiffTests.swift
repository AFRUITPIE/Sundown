import Testing
@testable import SundownKit

@Suite
struct UnifiedDiffTests {
    private let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,4 +10,5 @@ struct App {
         let a = 1
    -    let b = 2
    +    let b = 3
    +    let c = 4
         let d = 5
    \\ No newline at end of file
    diff --git a/old.txt b/new.txt
    similarity index 90%
    rename from old.txt
    rename to new.txt
    diff --git a/logo.png b/logo.png
    Binary files a/logo.png and b/logo.png differ
    """

    @Test func filesHunksAndCounts() {
        let files = UnifiedDiff.parse(diff)
        #expect(files.map(\.path) == ["Sources/App.swift", "new.txt", "logo.png"])
        let app = files[0]
        #expect(app.added == 2 && app.removed == 1)
        #expect(app.hunks.count == 1)
        #expect(app.hunks[0].header.hasPrefix("@@ -10,4 +10,5 @@"))
    }

    @Test func linesAreNumberedOnTheirSide() {
        let lines = UnifiedDiff.parse(diff)[0].hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(lines[0].oldNumber == 10 && lines[0].newNumber == 10)
        #expect(lines[1].oldNumber == 11 && lines[1].newNumber == nil)
        #expect(lines[2].newNumber == 11 && lines[3].newNumber == 12)
        #expect(lines[4].oldNumber == 12 && lines[4].newNumber == 13)
        #expect(lines[1].text == "    let b = 2")
    }

    @Test func renamesAndBinaries() {
        let files = UnifiedDiff.parse(diff)
        #expect(files[1].oldPath == "old.txt")
        #expect(files[2].isBinary)
    }

    @Test func anUntrackedFileIsAllAdded() {
        let file = FileDiff.added(path: "notes.md", content: "one\ntwo\n")
        #expect(file.added == 2 && file.removed == 0)
        #expect(file.hunks[0].lines.map(\.newNumber) == [1, 2])
    }

    @Test func nothingChangedIsNoFiles() {
        #expect(UnifiedDiff.parse("").isEmpty)
    }

    private func added(_ count: Int, path: String = "big.txt", header: String? = nil, line: (Int) -> String = { "line \($0)" }) -> String {
        let body = (1...count).map { "+" + line($0) }.joined(separator: "\n")
        return """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        \(header ?? "@@ -0,0 +1,\(count) @@")
        \(body)
        """
    }

    /// A huge file keeps only so many lines, and says how many it left out, but counts them all.
    @Test func aHugeFileKeepsItsFirstLinesAndCountsTheRest() {
        let file = UnifiedDiff.parse(added(UnifiedDiff.maxLinesPerFile + 10))[0]
        #expect(file.lineCount == UnifiedDiff.maxLinesPerFile)
        #expect(file.omittedLines == 10)
        #expect(file.added == UnifiedDiff.maxLinesPerFile + 10)

        let untracked = FileDiff.added(path: "gen.txt", content: String(repeating: "x\n", count: UnifiedDiff.maxLinesPerFile + 3))
        #expect(untracked.lineCount == UnifiedDiff.maxLinesPerFile && untracked.omittedLines == 3)
        #expect(untracked.added == UnifiedDiff.maxLinesPerFile + 3)
    }

    /// A minified file's one enormous line is cut short.
    @Test func aVeryLongLineIsClipped() {
        let line = UnifiedDiff.parse(added(1) { _ in String(repeating: "a", count: 50_000) })[0].hunks[0].lines[0]
        #expect(line.text.count == UnifiedDiff.maxLineLength + 1)
        #expect(line.text.hasSuffix("…"))
    }

    /// Staged and unstaged edits to one file are one file, and two hunks with the same header are
    /// still two, each with its own id.
    @Test func stagedAndUnstagedHunksAreOneFileWithDistinctHunks() async {
        let hunk = "@@ -1,0 +1,2 @@"
        let files = await UnifiedDiff.workingTree(staged: added(2, path: "a.swift", header: hunk),
                                                  unstaged: added(2, path: "a.swift", header: hunk) + "\n" + added(1, path: "b.swift"),
                                                  untracked: [("c.png", nil), ("d.md", "one\n")])
        #expect(files.map(\.path) == ["a.swift", "b.swift", "c.png", "d.md"])
        #expect(files[0].hunks.map(\.id) == [0, 1])
        #expect(files[0].added == 4)
        #expect(files[2].isBinary)
        #expect(WorkingChanges(branch: nil, files: files).added == 6)
    }
}
