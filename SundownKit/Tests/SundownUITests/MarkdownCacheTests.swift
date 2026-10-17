#if DEBUG
import Foundation
import Testing
@testable import SundownKit
@testable import SundownUI

/// The cache parses a streaming message a piece at a time; what it returns must be what parsing the
/// whole text at once returns, at every step.
@MainActor
@Suite
struct MarkdownCacheTests {
    private func streamed(_ text: String, chunk: Int, settles: Bool = false) -> [MarkdownView.Block] {
        let cache = MarkdownCache()
        defer { if settles { #expect(cache.settledLength > 0) } }
        var rest = Substring(text)
        var shown = ""
        var last: [MarkdownView.Block] = []
        while !rest.isEmpty {
            shown += rest.prefix(chunk)
            rest = rest.dropFirst(chunk)
            last = cache.blocks(for: shown).map(\.block)
            #expect(last == MarkdownView.parse(shown), "diverged after \(shown.utf8.count) bytes")
        }
        return last
    }

    @Test func streamingMatchesParsingTheWholeText() {
        let text = (0..<4).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n")
        #expect(text.utf8.count > 2048) // long enough for the settled prefix to be used
        #expect(streamed(text, chunk: 7, settles: true) == MarkdownView.parse(text))
    }

    @Test func aBlankLineInsideACodeFenceDoesNotSettleIt() {
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 90)
        let text = filler + "\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter the fence — with an em dash and “quotes”.\n"
        #expect(streamed(text, chunk: 5, settles: true) == MarkdownView.parse(text))
    }

    @Test func settledBlocksKeepTheirIdentityAsTheTailGrows() {
        let cache = MarkdownCache()
        let long = (0..<4).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n")
        let first = cache.blocks(for: long)
        let next = cache.blocks(for: long + " more")
        // Everything but the growing tail is the same parse, so its views compare equal.
        #expect(first.dropLast().map(\.id) == next.dropLast().map(\.id))
    }

    @Test func aShortMessagesUnchangedBlocksKeepTheirIdentity() {
        let cache = MarkdownCache()
        let first = cache.blocks(for: "# Plan\n\n- one\n- two\n\nWriting the th")
        let next = cache.blocks(for: "# Plan\n\n- one\n- two\n\nWriting the third step")
        #expect(first.dropLast().map(\.id) == next.dropLast().map(\.id))
        #expect(first.last?.id != next.last?.id)
    }

    /// A row made again (its chat reopened, or scrolled back into view) reuses the parse.
    @Test func aNewViewOfAKnownMessageReusesItsParse() {
        let text = "# Reused\n\nA paragraph with `code` in it.\n\n- one\n- two"
        let first = MarkdownCache().blocks(for: text)
        let again = MarkdownCache().blocks(for: text)
        #expect(again.map(\.id) == first.map(\.id))
        // And it can still grow from there, as a streaming message would.
        let grown = MarkdownCache()
        _ = grown.blocks(for: text)
        #expect(grown.blocks(for: text + " three").map(\.block) == MarkdownView.parse(text + " three"))
    }

    /// A page of replies parsed ahead of its rows: a row made for one then reuses that parse.
    @Test func prewarmedMessagesReuseTheirParse() async {
        let texts = (0..<3).map { "# Reply \($0) \(UUID())\n\nSome `code` and **bold**.\n\n- one\n- two" }
        await MarkdownCache.prewarm(texts + [texts[0]])
        for text in texts {
            let known = MarkdownCache.recent.blocks(for: text)
            #expect(known?.map(\.block) == MarkdownView.parse(text))
            #expect(MarkdownCache().blocks(for: text).map(\.id) == known?.map(\.id))
        }
    }

    /// Each length of a streaming reply would be a key never looked up again; the finished reply is
    /// the one worth keeping.
    @Test func aStreamingReplyIsRememberedOnceItHasArrived() {
        let text = "Streaming \(UUID()) reply, arriving a piece at a time."
        let cache = MarkdownCache()
        _ = cache.blocks(for: String(text.prefix(12)), streaming: true)
        _ = cache.blocks(for: text, streaming: true)
        #expect(!MarkdownCache.recent.contains(String(text.prefix(12))))
        #expect(!MarkdownCache.recent.contains(text))
        _ = cache.blocks(for: text, streaming: false)
        #expect(MarkdownCache.recent.contains(text))
    }

    @Test func recentParsesKeepToTheirBudgetAndDropTheLeastRecentlyUsed() {
        let recent = RecentParses(maxCount: 10, maxBytes: 1_000)
        let texts = (0..<4).map { String(repeating: "\($0)", count: 200) + "!" } // 201 bytes each
        for text in texts { recent.remember(text, []) }
        #expect(recent.count == 4)
        _ = recent.blocks(for: texts[0]) // used, so the second is now the oldest
        recent.remember(String(repeating: "x", count: 201), [])
        recent.remember(String(repeating: "y", count: 201), [])
        #expect(recent.bytes <= 1_000)
        #expect(recent.contains(texts[0]))
        #expect(!recent.contains(texts[1]))
        // Too big for the budget to be worth it.
        recent.remember(String(repeating: "z", count: 400), [])
        #expect(!recent.contains(String(repeating: "z", count: 400)))

        let counted = RecentParses(maxCount: 2, maxBytes: 1_000)
        for text in ["a", "b", "c"] { counted.remember(text, []) }
        #expect(counted.count == 2)
        #expect(!counted.contains("a"))
    }

    /// Inline text built from the parsed tree reads as Foundation's inline parser read it before:
    /// the same characters, emphasis, code and links, GitHub's autolinks included.
    @Test func inlineTextMatchesFoundationsParser() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        func runs(_ text: AttributedString) -> [String] {
            text.runs.map { run in
                "\(String(text[run.range].characters))|\(run.link?.absoluteString ?? "")|\(run.inlinePresentationIntent?.rawValue ?? 0)"
            }
        }
        let samples = [
            "Plain words, with punctuation. (1 + 2) = 3; {x} #tag %d ^ | ' \" ?", "日本語のテキスト、句読点。",
            "emoji 👍🏽 and é and e\u{301}", "a -- b ... c — d", "a\u{00A0}b", "example.com/path and README.md",
            "**bold** and _it_ and ***both*** and ~~gone~~", "Run `a *b* c` now", "a & b &amp; c \\* d",
            "See [the docs](https://a.b/c) and [a file](Sources/App.swift).",
            "mail a@b.com now", "see https://apple.com.", "foo www.bar.com x", "(see https://x.com/a_(b)_c).",
            "http://localhost:3000/path, then", "\"https://github.com/swiftlang/swift-markdown\"", "<https://x.y>",
        ]
        for sample in samples {
            let tree = try #require(MarkdownView.parse(sample).first)
            guard case .paragraph(let text, _) = tree else { Issue.record("\(sample.debugDescription): \(tree)"); continue }
            #expect(runs(text) == runs(try AttributedString(markdown: sample, options: options)), "\(sample.debugDescription)")
        }
    }

    /// Lines that start like a heading or a list item but aren't one stay in their paragraph, as
    /// CommonMark has it: a list item indented less than four spaces is at the top level, and only
    /// ASCII digits number one ("½." doesn't), so that line runs on in the item's text.
    @Test func lookalikeLinesParseAsCommonMarkHasThem() {
        let text = "#hashtag\n####### seven\n-dash\n12 apples\n3.5 kg\n  * star item\n½. half\n## Title"
        #expect(MarkdownView.parse(text) == [
            .paragraph("#hashtag ####### seven -dash 12 apples 3.5 kg"),
            .bullet(indent: 0, marker: "•", text: "star item ½. half"),
            .heading(level: 2, text: "Title"),
        ])
    }

    @Test func nestedListsKeepTheirDepth() {
        let text = "- one\n  - nested\n    - deeper\n  - again\n- two\n  1. first\n  2. second"
        #expect(MarkdownView.parse(text) == [
            .bullet(indent: 0, marker: "•", text: "one"),
            .bullet(indent: 1, marker: "•", text: "nested"),
            .bullet(indent: 2, marker: "•", text: "deeper"),
            .bullet(indent: 1, marker: "•", text: "again"),
            .bullet(indent: 0, marker: "•", text: "two"),
            .bullet(indent: 1, marker: "1.", text: "first"),
            .bullet(indent: 1, marker: "2.", text: "second"),
        ])
    }

    /// Code and paragraphs after an item's first line are the item's, one level in, and the list
    /// goes on after them.
    @Test func codeAndParagraphsInsideAListItemAreTheItems() {
        let text = "1. Install it:\n\n   ```sh\n   brew install x\n   ```\n\n   Then check it.\n2. Run it."
        #expect(MarkdownView.parse(text) == [
            .bullet(indent: 0, marker: "1.", text: "Install it:"),
            .code(lang: "sh", body: "brew install x", indent: 1),
            .paragraph("Then check it.", indent: 1),
            .bullet(indent: 0, marker: "2.", text: "Run it."),
        ])
    }

    @Test func anOrderedListKeepsItsOwnNumbers() {
        #expect(MarkdownView.parse("3. three\n4. four\n9. counted on") == [
            .bullet(indent: 0, marker: "3.", text: "three"),
            .bullet(indent: 0, marker: "4.", text: "four"),
            .bullet(indent: 0, marker: "5.", text: "counted on"),
        ])
    }

    @Test func setextHeadingsAreHeadings() {
        #expect(MarkdownView.parse("Title\n=====\n\nSubtitle\n---\n\nText") == [
            .heading(level: 1, text: "Title"), .heading(level: 2, text: "Subtitle"), .paragraph("Text"),
        ])
    }

    @Test func tasksQuotesAndTablesParse() {
        #expect(MarkdownView.parse("- [x] done\n- [ ] to do") == [
            .bullet(indent: 0, marker: "•", task: true, text: "done"),
            .bullet(indent: 0, marker: "•", task: false, text: "to do"),
        ])
        // A quote's lines are one paragraph; a blank line starts another.
        #expect(MarkdownView.parse("> one\n> line\n>\n> two") == [.quote("one line"), .quote("two")])
        #expect(MarkdownView.parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | | 3 |") == [
            .table([["a", "b", "c"], ["1", "", "3"]], alignments: [.left, .center, .right]),
        ])
    }

    /// The settled prefix ends where the last top-level element starts, so a long reply whose tail
    /// is a list or an open code fence parses as the whole text does, and what came before keeps
    /// its identity.
    @Test func aStreamedTailEndingMidListOrMidFenceParsesAsTheWhole() {
        let filler = (0..<3).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n")
        #expect(filler.utf8.count > 2048)
        let list = filler + "\n\n1. first\n\n   more about it\n2. sec"
        let fence = filler + "\n\nIntro:\n\n```swift\nlet a = 1\n\nlet b"
        for text in [list, fence] {
            let cache = MarkdownCache()
            let before = cache.blocks(for: String(text.dropLast(3)))
            let after = cache.blocks(for: text)
            #expect(after.map(\.block) == MarkdownView.parse(text))
            #expect(before.dropLast().prefix(10).map(\.id) == after.prefix(10).map(\.id))
        }
        #expect(MarkdownView.parse(fence).last == .code(lang: "swift", body: "let a = 1\n\nlet b"))
        #expect(MarkdownView.parse(list).suffix(3) == [
            .bullet(indent: 0, marker: "1.", text: "first"), .paragraph("more about it", indent: 1),
            .bullet(indent: 0, marker: "2.", text: "sec"),
        ])
    }

    /// While a reply streams, a last line of only "-" waits: under a paragraph it would make that
    /// paragraph a heading for a frame, before the item it usually starts arrives.
    @Test func aStreamingDashDoesNotMakeAHeading() {
        let cache = MarkdownCache()
        #expect(cache.blocks(for: "Found these:\n-", streaming: true).map(\.block) == [.paragraph("Found these:")])
        #expect(cache.blocks(for: "Found these:\n- one", streaming: true).map(\.block) == [
            .paragraph("Found these:"), .bullet(indent: 0, marker: "•", text: "one"),
        ])
        let settled = MarkdownCache()
        _ = settled.blocks(for: "Title\n-", streaming: true)
        // Once it has arrived it's what CommonMark says.
        #expect(settled.blocks(for: "Title\n-").map(\.block) == [.heading(level: 2, text: "Title")])
    }

    /// A prompt keeps the lines the person broke with Shift-Return; a reply's single newline is a space.
    @Test func promptsKeepTheirLineBreaks() {
        let text = "First line\nsecond line\n\n- item"
        #expect(MarkdownView.parse(text) == [.paragraph("First line second line"), .bullet(indent: 0, marker: "•", text: "item")])
        #expect(MarkdownView.parse(text, lineBreaks: true) == [.paragraph("First line\nsecond line"), .bullet(indent: 0, marker: "•", text: "item")])
        let cache = MarkdownCache()
        #expect(cache.blocks(for: text, lineBreaks: true).map(\.block) == MarkdownView.parse(text, lineBreaks: true))
    }

    @Test func replacedTextIsParsedAfresh() {
        let cache = MarkdownCache()
        let long = (0..<4).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n")
        _ = cache.blocks(for: long)
        let other = "# Another message\n\nShort."
        #expect(cache.blocks(for: other).map(\.block) == MarkdownView.parse(other))
    }
}
#endif
