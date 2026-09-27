import Testing
@testable import TetherKit

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
}
