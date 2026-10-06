#if DEBUG
import Foundation
import Testing
@testable import SundownUI

/// The message field helps type Markdown as an editor does.
@Suite
struct ComposerEditingTests {
    typealias Edit = ComposerEditing.Edit

    /// The text after `edit`, with "|" where the caret is (or "‹…›" around the selection).
    private func result(_ text: String, _ edit: Edit?) -> String {
        guard let edit else { return "unchanged" }
        let edited = (text as NSString).replacingCharacters(in: edit.range, with: edit.text) as NSString
        if edit.selection.length == 0 { return edited.replacingCharacters(in: edit.selection, with: "|") }
        let inner = edited.substring(with: edit.selection)
        return edited.replacingCharacters(in: edit.selection, with: "‹\(inner)›")
    }

    /// `text` with "|" marking the caret: the text, and the caret's range.
    private func caret(_ marked: String) -> (String, NSRange) {
        let location = (marked as NSString).range(of: "|").location
        return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: location, length: 0))
    }

    private func newLine(_ marked: String) -> String {
        let (text, selection) = caret(marked)
        return result(text, ComposerEditing.newLine(in: text, selection: selection))
    }

    @Test func aNewLineContinuesTheList() {
        #expect(newLine("* Foobar|") == "* Foobar\n* |")
        #expect(newLine("- one\n- two|") == "- one\n- two\n- |")
        #expect(newLine("9. nine|") == "9. nine\n10. |")
        #expect(newLine("1) first|") == "1) first\n2) |")
        #expect(newLine("- [x] done|") == "- [x] done\n- [ ] |")
        #expect(newLine("> quoted|") == "> quoted\n> |")
        #expect(newLine("  - nested|") == "  - nested\n  - |")
    }

    @Test func anEmptyItemEndsTheList() {
        #expect(newLine("- one\n- |") == "- one\n|")
        #expect(newLine("- one\n  - |") == "- one\n- |")
        #expect(newLine("- [ ] |") == "|")
        #expect(newLine("> |") == "|")
    }

    @Test func aPlainLineKeepsItsIndent() {
        #expect(newLine("words|") == "words\n|")
        #expect(newLine("    code|") == "    code\n    |")
        // Before the marker, it's only a line break.
        #expect(newLine("|- item") == "\n|- item")
        #expect(newLine("- item and| more") == "- item and\n- | more")
    }

    @Test func tabNestsListItems() {
        let (text, selection) = caret("- one\n- two|")
        #expect(result(text, ComposerEditing.indent(in: text, selection: selection, outward: false)) == "- one\n  - two|")
        let (nested, at) = caret("- one\n  - two|")
        #expect(result(nested, ComposerEditing.indent(in: nested, selection: at, outward: true)) == "- one\n- two|")
        let (numbered, n) = caret("1. one\n2. two|")
        #expect(result(numbered, ComposerEditing.indent(in: numbered, selection: n, outward: false)) == "1. one\n   2. two|")
        let (plain, p) = caret("just words|")
        #expect(ComposerEditing.indent(in: plain, selection: p, outward: false) == nil)
    }

    @Test func wrappingASelection() {
        let text = "make this bold"
        let word = NSRange(location: 10, length: 4)
        #expect(result(text, ComposerEditing.wrap(in: text, selection: word, open: "**", close: "**")) == "make this **‹bold›**")
        let bold = "make this **bold**"
        let inner = NSRange(location: 12, length: 4)
        #expect(result(bold, ComposerEditing.wrap(in: bold, selection: inner, open: "**", close: "**")) == "make this ‹bold›")
        // Italic inside bold is added, not mistaken for bold's own asterisks.
        #expect(result(bold, ComposerEditing.wrap(in: bold, selection: inner, open: "*", close: "*")) == "make this ***‹bold›***")
        let both = "***x***"
        #expect(result(both, ComposerEditing.wrap(in: both, selection: NSRange(location: 3, length: 1), open: "*", close: "*")) == "**‹x›**")
        #expect(result("", ComposerEditing.wrap(in: "", selection: NSRange(location: 0, length: 0), open: "**", close: "**")) == "**|**")
    }

    @Test func links() {
        let text = "see the docs"
        let words = NSRange(location: 4, length: 8)
        #expect(result(text, ComposerEditing.link(in: text, selection: words)) == "see [the docs](|)")
        #expect(result("", ComposerEditing.link(in: "", selection: NSRange(location: 0, length: 0))) == "[|]()")
        #expect(result(text, ComposerEditing.link(in: text, selection: words, url: "https://a.b")) == "see [the docs](https://a.b)|")
        #expect(ComposerEditing.isURL(" https://apple.com/x?y=1 "))
        #expect(!ComposerEditing.isURL("not a link"))
        #expect(!ComposerEditing.isURL("file:///etc"))
    }
}
#endif
