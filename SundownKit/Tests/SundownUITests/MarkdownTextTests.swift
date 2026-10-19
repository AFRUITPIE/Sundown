#if DEBUG
import AppKit
import Testing
@testable import SundownUI

/// The composer styles Markdown as it's typed, and a message's text copies as plain text.
@MainActor
@Suite
struct MarkdownTextTests {
    typealias Style = ComposerMarkdown.Style

    /// The characters of `text` styled with `matching`, as one string per run.
    private func runs(_ text: String, where matching: (Style) -> Bool) -> [String] {
        let styles = ComposerMarkdown.styles(for: text)
        var out: [String] = []
        var current = ""
        for (character, style) in zip(text, styles) {
            if matching(style) { current.append(character) } else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    @Test func everyCharacterHasAStyle() {
        for text in ["", "a", "é\n\n👩‍💻 `x`", "**unclosed", "```\ncode\n", "- [ ] task\n> quote\n# Heading"] {
            #expect(ComposerMarkdown.styles(for: text).count == text.count, "\(text.debugDescription)")
        }
    }

    @Test func emphasisIsStyledAndItsSyntaxDimmed() {
        let text = "Some **bold**, *italic*, ***both*** and ~~gone~~."
        #expect(runs(text) { $0.bold && !$0.italic } == ["bold"])
        #expect(runs(text) { $0.italic && !$0.bold } == ["italic"])
        #expect(runs(text) { $0.italic && $0.bold } == ["both"])
        #expect(runs(text) { $0.strike } == ["gone"])
        #expect(runs(text) { $0.tone == .syntax } == ["**", "**", "*", "*", "***", "***", "~~", "~~"])
    }

    @Test func unclosedOrSpacedDelimitersStayPlain() {
        #expect(runs("2 * 3 * 4 and **open") { $0.bold || $0.italic }.isEmpty)
        #expect(runs("snake_case_name") { $0.italic }.isEmpty)
    }

    @Test func codeKeepsItsCharactersFromOtherSyntax() {
        let text = "Run `a *b* c` now"
        #expect(runs(text) { $0.fill } == ["a *b* c"])
        #expect(runs(text) { $0.italic }.isEmpty)
    }

    @Test func blocksAreStyledByLine() {
        let text = "# Title\n> quoted\n- [x] done\n1. first\n```swift\nlet *x* = 1\n```"
        #expect(runs(text) { $0.heading == 1 } == ["# Title"])
        #expect(runs(text) { $0.tone == .secondary } == ["quoted", "- [x]", "1. "])
        #expect(runs(text) { $0.code } == ["```swift", "let *x* = 1", "```"])
        #expect(runs(text) { $0.italic }.isEmpty)
    }

    @Test func linksMentionsAndCommandsAreAccented() {
        #expect(runs("See [the docs](https://a.b) and @src/App.swift") { $0.tone == .accent } == ["the docs", "@src/App.swift"])
        #expect(runs("/review this") { $0.tone == .accent } == ["/review"])
        #expect(runs("a/b and email@x") { $0.tone == .accent }.isEmpty)
    }

    @Test func copyIsPlainText() {
        let markdown = "Intro\n\n- one\n\n  2. two\n\n---\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```"
        #expect(MarkdownBuilder.plainText(markdown) == "Intro\n\n• one\n  2. two\n\n\n\nA\tB\n1\t2\n\nlet x = 1")
    }

    @Test func emptyTableCellsKeepTheirColumns() {
        #expect(MarkdownBuilder.plainText("| A | B | C |\n|---|---|---|\n| a | | |") == "A\tB\tC\na\t\t")
    }
}
#endif
