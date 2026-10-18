#if DEBUG
import AppKit
import Foundation
@testable import SundownFixtures
import Testing
@testable import SundownKit
@testable import SundownUI

/// A message's Markdown as the text it's drawn with: what each construct becomes, and a streamed
/// reply built a piece at a time coming out as the whole text built at once, at every step. Off
/// the main actor (the builder is nonisolated), so other suites' main-actor tests don't wait on it.
@Suite
struct MarkdownBuilderTests {
    private let theme = MarkdownTheme.standard

    /// Each run of the text and what it's drawn with, comparable across two builds.
    private func signature(_ text: NSAttributedString) -> [String] {
        var out: [String] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let p = attributes[.paragraphStyle] as? NSParagraphStyle
            let font = attributes[.font] as? NSFont
            let decoration = (attributes[.markdownDecoration] as? MarkdownDecoration).map { if case .code(let language, _) = $0.kind { "code \(language)" } else { "\($0.kind)" } } ?? ""
            out.append([
                (text.string as NSString).substring(with: range), font.map { "\($0.fontName) \($0.pointSize)" } ?? "",
                p.map { "\($0.headIndent) \($0.firstLineHeadIndent) \($0.paragraphSpacingBefore) \($0.alignment.rawValue) \($0.textBlocks.count)" } ?? "",
                "\(attributes[.link] ?? "")", "\(attributes[.markdownHeading] ?? "")", decoration,
                "\(attributes[.markdownCopyAs] ?? "")", attributes[.attachment] == nil ? "" : "box",
            ].joined(separator: "|"))
        }
        return out
    }

    /// The text streamed in pieces, checked against building it whole after each one. The pieces
    /// end where it matters: on each side of every line's end, one character into every
    /// line (where "|" or "-" could still become anything), and every 61st character between.
    private func streamed(_ text: String, settles: Bool = false) -> NSAttributedString {
        var cuts: Set<String.Index> = [text.endIndex]
        for (n, i) in text.indices.enumerated() {
            if n % 61 == 0 { cuts.insert(i) }
            guard text[i] == "\n" else { continue }
            cuts.insert(i)
            for ahead in 1...2 { text.index(i, offsetBy: ahead, limitedBy: text.endIndex).map { _ = cuts.insert($0) } }
        }
        var stream = MarkdownStream()
        let built = NSMutableAttributedString()
        for cut in cuts.sorted() where cut > text.startIndex {
            let shown = String(text[..<cut])
            _ = stream.update(built, to: shown, theme: theme, streaming: false)
            #expect(signature(built) == signature(MarkdownBuilder.build(shown, theme: theme)), "diverged after \(shown.utf8.count) bytes")
        }
        if settles { #expect(stream.settledLength > 0) }
        return built
    }

    private func headIndent(of words: String, in text: NSAttributedString) -> CGFloat? {
        let at = (text.string as NSString).range(of: words).location
        return (text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.headIndent
    }

    private func attribute(_ key: NSAttributedString.Key, of words: String, in text: NSAttributedString) -> Any? {
        text.attribute(key, at: (text.string as NSString).range(of: words).location, effectiveRange: nil)
    }

    @Test func streamingMatchesBuildingTheWholeText() {
        let text = (0..<2).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n")
        _ = streamed(text, settles: true)
    }

    @Test func aBlankLineInsideACodeFenceDoesNotSettleIt() {
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 20)
        _ = streamed(filler + "\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter the fence — with an em dash and “quotes”.\n",
                     settles: true)
    }

    /// The settled text isn't built again: only the last top-level element is replaced, once its
    /// first line is whole.
    @Test func onlyTheLastElementIsBuiltAgain() throws {
        var stream = MarkdownStream()
        let text = NSMutableAttributedString()
        _ = stream.update(text, to: "# Plan\n\n- one\n- two\n\nWriting the th", theme: theme, streaming: true)
        #expect(stream.settledLength == 0)
        _ = stream.update(text, to: "# Plan\n\n- one\n- two\n\nWriting the third step:\n", theme: theme, streaming: true)
        let before = text.string
        let update = stream.update(text, to: "# Plan\n\n- one\n- two\n\nWriting the third step:\nfirst", theme: theme, streaming: true)
        let change = try #require(update)
        #expect(change.start == (before as NSString).range(of: "\nWriting").location)
        #expect(change.replaced == "\nWriting the third step:")
        let again = stream.update(text, to: "# Plan\n\n- one\n- two\n\nWriting the third step:\nfirst", theme: theme, streaming: true)
        #expect(again == nil)
    }

    @Test func replacedTextIsBuiltAfresh() {
        var stream = MarkdownStream()
        let text = NSMutableAttributedString()
        _ = stream.update(text, to: (0..<4).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n"),
                          theme: theme, streaming: false)
        let other = "# Another message\n\nShort."
        _ = stream.update(text, to: other, theme: theme, streaming: false)
        #expect(signature(text) == signature(MarkdownBuilder.build(other, theme: theme)))
    }

    /// The settled prefix ends where the last top-level element starts, so a reply whose tail is a
    /// list or an open code fence builds as the whole text does.
    @Test func aStreamedTailEndingMidListOrMidFenceBuildsAsTheWhole() {
        let filler = PerformanceTranscript.markdown(section: 0)
        let list = streamed(filler + "\n\n1. first\n\n   more about it\n2. sec", settles: true)
        #expect(MarkdownBuilder.plain(list, in: NSRange(location: 0, length: list.length)).hasSuffix("1. first\n\nmore about it\n\n2. sec"))
        let fence = streamed(filler + "\n\nIntro:\n\n```swift\nlet a = 1\n\nlet b", settles: true)
        #expect(fence.string.hasSuffix("let a = 1\n\nlet b"))
    }

    /// While a reply streams, a last line of only "-" waits: under a paragraph it would make that
    /// paragraph a heading for a frame, before the item it usually starts arrives.
    @Test func aStreamingDashDoesNotMakeAHeading() {
        var stream = MarkdownStream()
        let text = NSMutableAttributedString()
        _ = stream.update(text, to: "Found these:\n-", theme: theme, streaming: true)
        #expect(text.string == "Found these:")
        #expect(attribute(.markdownHeading, of: "Found", in: text) == nil)
        _ = stream.update(text, to: "Found these:\n- one", theme: theme, streaming: true)
        #expect(MarkdownBuilder.plain(text, in: NSRange(location: 0, length: text.length)) == "Found these:\n\n• one")
        // Once it has arrived it's what CommonMark says.
        _ = stream.update(text, to: "Title\n-", theme: theme, streaming: true)
        _ = stream.update(text, to: "Title\n-", theme: theme, streaming: false)
        #expect(attribute(.markdownHeading, of: "Title", in: text) as? Int == 2)
    }

    /// A page of replies built ahead of their rows, kept for them; and a streaming reply's text only
    /// once it has arrived, since each length of it would be a key never looked up again.
    @MainActor @Test func builtTextIsKeptForSettledReplies() async {
        let texts = (0..<3).map { "# Reply \($0) \(UUID())\n\nSome `code` and **bold**.\n\n- one\n- two" }
        await MarkdownView.prewarm(texts + [texts[0]], theme: theme)
        for text in texts {
            let kept = MarkdownView.Coordinator.built(text, theme: theme)
            #expect(kept.map(signature) == signature(MarkdownBuilder.build(text, theme: theme)))
        }

        let reply = "Streaming \(UUID()) reply, arriving a piece at a time."
        let coordinator = MarkdownView.Coordinator()
        let view = MarkdownNSTextView.make()
        coordinator.view = view
        coordinator.apply(String(reply.prefix(12)), theme: theme, streams: true)
        coordinator.apply(reply, theme: theme, streams: true)
        #expect(MarkdownView.Coordinator.built(String(reply.prefix(12)), theme: theme) == nil)
        #expect(MarkdownView.Coordinator.built(reply, theme: theme) == nil)
        coordinator.apply(reply, theme: theme, streams: false)
        #expect(MarkdownView.Coordinator.built(reply, theme: theme)?.string == reply)
    }

    /// Inline text reads as Foundation's inline parser read it before: the same characters,
    /// emphasis, code and links, GitHub's autolinks included.
    @Test func inlineTextMatchesFoundationsParser() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        func merged(_ runs: [(String, String)]) -> [String] {
            var out: [(String, String)] = []
            for run in runs {
                if let last = out.last, last.1 == run.1 { out[out.count - 1].0 += run.0 } else { out.append(run) }
            }
            return out.map { "\($0.0)|\($0.1)" }
        }
        func ours(_ text: NSAttributedString) -> [String] {
            var runs: [(String, String)] = []
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                let flags = [traits.contains(.bold) ? "b" : "", traits.contains(.italic) ? "i" : "",
                             attributes[.markdownInlineCode] != nil ? "c" : "", attributes[.strikethroughStyle] != nil ? "s" : ""]
                runs.append(((text.string as NSString).substring(with: range),
                             flags.joined() + " " + ((attributes[.link] as? URL)?.absoluteString ?? "")))
            }
            return merged(runs)
        }
        func foundations(_ text: AttributedString) -> [String] {
            merged(text.runs.map { run in
                let intent = run.inlinePresentationIntent ?? []
                let flags = [intent.contains(.stronglyEmphasized) ? "b" : "", intent.contains(.emphasized) ? "i" : "",
                             intent.contains(.code) ? "c" : "", intent.contains(.strikethrough) ? "s" : ""]
                return (String(text[run.range].characters), flags.joined() + " " + (run.link?.absoluteString ?? ""))
            })
        }
        let samples = [
            "Plain words, with punctuation. (1 + 2) = 3; {x} #tag %d ^ | ' \" ?", "日本語のテキスト、句読点。",
            "emoji 👍🏽 and é and e\u{301}", "a -- b ... c — d", "a\u{00A0}b", "example.com/path and README.md",
            "**bold** and _it_ and ***both*** and ~~gone~~", "Run `a *b* c` now", "a & b &amp; c \\* d",
            "See [the docs](https://a.b/c) and [a file](Sources/App.swift).",
            "mail a@b.com now", "see https://apple.com.", "foo www.bar.com x", "(see https://x.com/a_(b)_c and https://x.com/d).",
            "http://localhost:3000/path, then", "\"https://github.com/swiftlang/swift-markdown\"", "<https://x.y>",
        ]
        for sample in samples {
            #expect(ours(MarkdownBuilder.build(sample, theme: theme)) == foundations(try AttributedString(markdown: sample, options: options)),
                    "\(sample.debugDescription)")
        }
    }

    /// Lines that start like a heading or a list item but aren't one stay in their paragraph, as
    /// CommonMark has it: a list item indented less than four spaces is at the top level, and only
    /// ASCII digits number one ("½." doesn't), so that line runs on in the item's text.
    @Test func lookalikeLinesParseAsCommonMarkHasThem() {
        let text = MarkdownBuilder.build("#hashtag\n####### seven\n-dash\n12 apples\n3.5 kg\n  * star item\n½. half\n## Title", theme: theme)
        #expect(MarkdownBuilder.plain(text, in: NSRange(location: 0, length: text.length))
            == "#hashtag ####### seven -dash 12 apples 3.5 kg\n\n• star item ½. half\n\nTitle")
        #expect(attribute(.markdownHeading, of: "Title", in: text) as? Int == 2)
    }

    @Test func nestedListsKeepTheirDepth() {
        let text = MarkdownBuilder.build("- one\n  - nested\n    - deeper\n  - again\n- two\n  1. first\n  2. second", theme: theme)
        #expect(MarkdownBuilder.plain(text, in: NSRange(location: 0, length: text.length))
            == "• one\n  • nested\n    • deeper\n  • again\n• two\n  1. first\n  2. second")
        let indents = ["one", "nested", "deeper"].compactMap { headIndent(of: $0, in: text) }
        #expect(indents == indents.sorted() && Set(indents).count == 3)
    }

    /// Code and paragraphs after an item's first line are the item's, lined up with its text, and
    /// the list goes on after them.
    @Test func codeAndParagraphsInsideAListItemAreTheItems() throws {
        let text = MarkdownBuilder.build("1. Install it:\n\n   ```sh\n   brew install x\n   ```\n\n   Then check it.\n2. Run it.", theme: theme)
        #expect(MarkdownBuilder.plain(text, in: NSRange(location: 0, length: text.length))
            == "1. Install it:\n\nbrew install x\n\nThen check it.\n\n2. Run it.")
        let itemText = try #require(headIndent(of: "Install", in: text))
        #expect(itemText > 0)
        #expect(headIndent(of: "Then", in: text) == itemText)
        #expect(headIndent(of: "brew", in: text) == itemText + theme.codeInset)
    }

    @Test func anOrderedListKeepsItsOwnNumbers() {
        #expect(MarkdownBuilder.plainText("3. three\n4. four\n9. counted on") == "3. three\n4. four\n5. counted on")
    }

    @Test func setextHeadingsAreHeadings() {
        let text = MarkdownBuilder.build("Title\n=====\n\nSubtitle\n---\n\nText", theme: theme)
        #expect(attribute(.markdownHeading, of: "Title", in: text) as? Int == 1)
        #expect(attribute(.markdownHeading, of: "Subtitle", in: text) as? Int == 2)
        #expect(attribute(.markdownHeading, of: "Text", in: text) == nil)
    }

    @Test func tasksQuotesAndTables() {
        #expect(MarkdownBuilder.plainText("- [x] done\n- [ ] to do") == "[x] done\n[ ] to do")
        // A quote's lines are one paragraph; a blank line starts another.
        let quote = MarkdownBuilder.build("> one\n> line\n>\n> two", theme: theme)
        #expect(quote.string == "one line\ntwo")
        #expect((attribute(.markdownDecoration, of: "two", in: quote) as? MarkdownDecoration)?.kind == .quote)
        let table = MarkdownBuilder.build("| a | b | c |\n|:--|:-:|--:|\n| 1 | | 3 |", theme: theme)
        #expect(MarkdownBuilder.plain(table, in: NSRange(location: 0, length: table.length)) == "a\tb\tc\n1\t\t3")
        let alignments = ["a", "b", "c"].map { (attribute(.paragraphStyle, of: $0, in: table) as? NSParagraphStyle)?.alignment }
        #expect(alignments == [.left, .center, .right])
    }

    /// A prompt keeps the lines the person broke with Shift-Return; a reply's single newline is a space.
    @Test func promptsKeepTheirLineBreaks() {
        let markdown = "First line\nsecond line\n\n- item"
        #expect(MarkdownBuilder.plainText(markdown) == "First line second line\n\n• item")
        let prompt = MarkdownBuilder.build(markdown, theme: MarkdownTheme(style: .prompt, scale: 1, increasedContrast: false))
        #expect(MarkdownBuilder.plain(prompt, in: NSRange(location: 0, length: prompt.length)) == "First line\nsecond line\n\n• item")
    }
}
#endif
