import Testing
@testable import SundownUI

@Suite struct SyntaxHighlightTests {
    private func kinds(_ code: String, _ language: String) -> [(String, SyntaxHighlight.Kind)] {
        let bytes = Array(code.utf8)
        return SyntaxHighlight.scan(bytes, SyntaxHighlight.grammar(for: language)!).map {
            (String(decoding: bytes[$0.start..<$0.end], as: UTF8.self), $0.kind)
        }
    }

    @Test func swiftReadsAsXcodeColorsIt() {
        let runs = kinds("let s: String = \"a \\\" b\" // done\nreturn 42", "swift")
        #expect(runs.map(\.0) == ["let", "String", "\"a \\\" b\"", "// done", "return", "42"])
        #expect(runs.map(\.1) == [.keyword, .type, .string, .comment, .keyword, .number])
    }

    @Test func aHashStartsACommentOnlyWhereAWordCould() {
        let runs = kinds("echo $# a#b # note", "sh")
        #expect(runs.map(\.0) == ["# note"])
    }

    @Test func tripleQuotesRunAcrossLines() {
        let runs = kinds("x = '''one\ntwo'''", "python")
        #expect(runs.map(\.1) == [.string])
    }

    @Test func aFileNameGivesItsLanguageAndOutputStaysPlain() {
        #expect(SyntaxHighlight.grammar(for: "RootView.swift") != nil)
        #expect(SyntaxHighlight.grammar(for: "Output") == nil)
        #expect(SyntaxHighlight.attributed("plain", language: "Output") == nil)
    }

    @Test func coloringKeepsTheText() {
        let code = "func a() { return \"é\" } // ✓"
        #expect(String(SyntaxHighlight.attributed(code, language: "swift")!.characters) == code)
    }
}
