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
    private func streamed(_ text: String, chunk: Int) -> [MarkdownView.Block] {
        let cache = MarkdownCache()
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
        #expect(streamed(text, chunk: 7) == MarkdownView.parse(text))
    }

    @Test func aBlankLineInsideACodeFenceDoesNotSettleIt() {
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 90)
        let text = filler + "\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter the fence — with an em dash and “quotes”.\n"
        #expect(streamed(text, chunk: 5) == MarkdownView.parse(text))
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

    /// Text with no inline syntax skips the parser; it must come out exactly as the parser has it.
    @Test func plainTextSkipsTheParserUnchanged() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let samples = [
            "Plain words, with punctuation. (1 + 2) = 3; {x} #tag %d ^ | ' \" ?", "日本語のテキスト、句読点。",
            "emoji 👍🏽 and é and e\u{301}", "a -- b ... c — d", "  lead", "trail  ", "tab\there", "x  \ny",
            "1. not a list", "# not a heading", "- not a bullet", "a\u{00A0}b", "example.com/path", "a.b.com",
            // With syntax: parsed as before.
            "mail a@b.com now", "see https://apple.com", "foo www.bar.com", "x\r\ny", "a & b", "**bold** and _it_",
        ]
        for text in samples {
            let parsed = try AttributedString(markdown: text, options: options)
            #expect(MarkdownCache.inline(text) == parsed, "\(text.debugDescription)")
        }
        #expect(!MarkdownCache.mayHaveInlineSyntax("Just words."))
        #expect(MarkdownCache.mayHaveInlineSyntax("Visit WWW.example.com"))
        #expect(MarkdownCache.mayHaveInlineSyntax("a `b`"))
    }

    /// Lines that start like a heading or a list item but aren't one stay in their paragraph.
    @Test func lookalikeLinesParseAsBefore() {
        let text = "#hashtag\n####### seven\n-dash\n12 apples\n3.5 kg\n  * star item\n½. half\n## Title"
        #expect(MarkdownView.parse(text) == [
            .paragraph("#hashtag ####### seven -dash 12 apples 3.5 kg"),
            .bullet(indent: 1, marker: "•", text: "star item"),
            .bullet(indent: 0, marker: "½.", text: "half"),
            .heading(level: 2, text: "Title"),
        ])
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
