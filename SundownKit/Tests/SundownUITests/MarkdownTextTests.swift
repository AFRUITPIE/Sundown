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
        let theme = MarkdownTheme(style: .reply, scale: 1, increasedContrast: false)
        let blocks: [MarkdownView.Block] = [
            .paragraph("Intro"), .bullet(indent: 0, marker: "•", text: "one"), .bullet(indent: 1, marker: "2.", text: "two"),
            .rule, .table([["A", "B"], ["1", "2"]]), .code(lang: "swift", body: "let x = 1"),
        ]
        let text = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let rendered = MarkdownView.Rendered(id: i, block: block, inline: block.inlineText.map { AttributedString($0) })
            let spacing = i == 0 ? 0 : MarkdownBuilder.spacing(after: blocks[i - 1], before: block)
            text.append(MarkdownBuilder.build(rendered, leading: i > 0, spacing: spacing, widestMarker: nil, theme: theme))
        }
        let plain = MarkdownNSTextView.plain(text, in: NSRange(location: 0, length: text.length))
        #expect(plain == "Intro\n\n• one\n  2. two\n\n\n\nA\tB\n1\t2\n\nlet x = 1")
    }

    @Test func emptyTableCellsKeepTheirColumns() {
        let theme = MarkdownTheme(style: .reply, scale: 1, increasedContrast: false)
        let block = MarkdownView.Block.table([["A", "B", "C"], ["a", "", ""]])
        let text = MarkdownBuilder.build(MarkdownView.Rendered(id: 0, block: block, inline: block.inlineText.map { AttributedString($0) }),
                                         leading: false, spacing: 0, widestMarker: nil, theme: theme)
        #expect(MarkdownNSTextView.plain(text, in: NSRange(location: 0, length: text.length)) == "A\tB\tC\na\t\t")
    }
}
#endif
