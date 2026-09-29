import SwiftUI
import Testing
@testable import TetherUI

@Suite
struct LiveMarkdownTests {
    /// Each span as the text it covers and its style, in order of where it starts.
    private func spans(_ text: String) -> [String] {
        LiveMarkdown.spans(in: text)
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { "\(text[$0.range])=\($0.style)" }
    }

    @Test func boldItalicAndCode() {
        #expect(spans("a **b** *c* `d`") == ["**=marker", "b=strong", "**=marker", "*=marker", "c=emphasis", "*=marker",
                                              "`=marker", "d=code", "`=marker"])
    }

    @Test func aLinksTextIsTheLinkAndItsTargetIsSyntax() {
        #expect(spans("see [the issue](https://x.com/a_b)") == ["[=marker", "the issue=link", "](https://x.com/a_b)=marker"])
    }

    @Test func headingsAndQuotes() {
        #expect(spans("## Title") == ["## =marker", "Title=heading(2)"])
        #expect(spans("> said") == ["> =marker", "said=quote"])
    }

    /// Nothing inside a code span or fence is syntax.
    @Test func codeIsLeftAlone() {
        #expect(spans("`**x**`") == ["`=marker", "**x**=code", "`=marker"])
        #expect(spans("```\n**x**\n```") == ["```=marker", "**x**=codeBlock", "```=marker"])
    }

    /// Underscores inside words, a list's leading asterisk and the halves of a bold's markers aren't italic.
    @Test func notItalic() {
        #expect(spans("snake_case_name") == [])
        #expect(spans("* item") == [])
        #expect(spans("**bold**").contains("bold=strong"))
        #expect(!spans("**bold**").contains { $0.hasSuffix("=emphasis") })
    }

    /// Only attributes are ever set: the draft is sent as typed.
    @Test func plainTextIsUntouched() {
        #expect(spans("just words").isEmpty)
        #expect(spans("").isEmpty)
    }

    /// The link's text is tinted and its brackets and target dimmed.
    @Test func aLinksRunsAreStyled() {
        var text = AttributedString("see [x](https://a.b)")
        LiveMarkdown.style(&text, scale: 1)
        let runs = text.runs.map { "\(String(text[$0.range].characters))=\($0.foregroundColor.map { "\($0)" } ?? "nil")" }
        print("[runs]", runs)
        #expect(runs.count == 4)
    }
}
