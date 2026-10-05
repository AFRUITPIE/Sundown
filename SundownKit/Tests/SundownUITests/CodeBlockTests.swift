import Testing
@testable import SundownUI

/// A code block counts its lines once, in bytes, and draws only what's shown while collapsed.
@Suite
struct CodeBlockTests {
    @Test(arguments: ["", "one", "one\n", "one\ntwo\nthree", "\n\n", "é\nñ👍🏽\n日本"])
    func countsLinesAsTheCharactersDid(code: String) {
        let characters = code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        #expect(CodeBlock.measure(code, limit: nil).lines == characters, "\(code.debugDescription)")
    }

    /// A Windows line ending is one Character, which the old count missed; Text breaks there.
    @Test func aWindowsLineEndingIsOneBreak() {
        #expect(CodeBlock.measure("a\r\nb", limit: nil).lines == 2)
    }

    /// Collapsed, the lines shown and one more, so the last line shown still ends in an ellipsis.
    @Test func drawsOnlyTheShownLinesAndOneMore() {
        let code = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let measure = CodeBlock.measure(code, limit: 8)
        #expect(measure.lines == 30)
        #expect(measure.collapsedEnd.map { String(code[..<$0]) } == (1...9).map { "line \($0)" }.joined(separator: "\n"))

        // Nothing to cut when it's no longer than that.
        #expect(CodeBlock.measure("a\nb\nc", limit: 2).collapsedEnd == nil)
        #expect(CodeBlock.measure("a\nb\nc\nd", limit: 2).collapsedEnd.map { String("a\nb\nc\nd"[..<$0]) } == "a\nb\nc")
        #expect(CodeBlock.measure(code, limit: nil).collapsedEnd == nil)
    }

    /// A diff is drawn as runs of one kind; the runs hold every line, in order, with its sign.
    @Test func diffRunsGroupLinesOfOneKind() {
        let diff = DiffView.diff(.init(old: "a\nb\nc\nd", new: "a\nB\nC\nd\ne"), lineLimit: 3)
        #expect(diff.lineCount == 7)
        #expect(diff.all.map(\.sign) == [" ", "-", "+", " ", "+"])
        #expect(diff.all.map(\.text) == ["  a", "- b\n- c", "+ B\n+ C", "  d", "+ e"])
        #expect(diff.all[1].spoken == "b\nc")
        #expect(diff.collapsed.map(\.text) == ["  a", "- b\n- c"])
        let lines = DiffView.diff(old: "a\nb\nc\nd", new: "a\nB\nC\nd\ne")
        #expect(diff.all.map(\.text).joined(separator: "\n") == lines.map { "\($0.sign) \($0.text)" }.joined(separator: "\n"))
    }
}
