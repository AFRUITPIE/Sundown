#if DEBUG
import Foundation
import Testing
@testable import TetherKit
@testable import TetherUI

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

    @Test func replacedTextIsParsedAfresh() {
        let cache = MarkdownCache()
        let long = (0..<4).map { PerformanceTranscript.markdown(section: $0) }.joined(separator: "\n\n")
        _ = cache.blocks(for: long)
        let other = "# Another message\n\nShort."
        #expect(cache.blocks(for: other).map(\.block) == MarkdownView.parse(other))
    }
}
#endif
