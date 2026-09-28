import Foundation
import Testing
@testable import TetherKit

/// The Activity sidebar's preview stops reading a reply once it has enough prose; what it makes
/// must be what reading the whole reply made.
@MainActor
@Suite
struct ReplyPreviewTests {
    /// The preview as it was made before: every line of the reply read.
    private func wholeReply(_ markdown: String, limit: Int = 300) -> String {
        var prose: [String] = []
        var code: [String] = []
        var inFence = false
        for raw in markdown.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { code.append(line); continue }
            if line.allSatisfy({ "-*_|: ".contains($0) }) { continue }
            line = line.replacing(/^(#{1,6}|>+|[-*+]|\d+[.)])\s+/, with: "")
            line = line.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
            for marker in ["**", "__", "~~", "`", "*"] { line = line.replacingOccurrences(of: marker, with: "") }
            line = line.replacingOccurrences(of: "|", with: " ")
            prose.append(line)
        }
        let text = (prose.isEmpty ? code : prose).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    nonisolated private static let replies: [String] = {
        let paragraph = "The **reducer** keeps items in `order`, see [the docs](https://example.com). "
        return [
            "",
            "Short.",
            "```\nswift build\n```",
            "```swift\nlet a = 1\n```\n\nThen prose after the code.",
            String(repeating: paragraph, count: 20),
            (0..<200).map { "- item \($0) with a few words" }.joined(separator: "\n"),
            (0..<50).map { "Line \($0)\r\n" }.joined(),
            "## Heading\n\n" + String(repeating: "word ", count: 59) + "\n\n" + String(repeating: "more ", count: 100),
            String(repeating: "a", count: 299) + "\n" + "b c d",
            String(repeating: "x", count: 300) + "\nnext",
            "| a | b |\n|---|---|\n" + (0..<100).map { "| \($0) | value \($0) |" }.joined(separator: "\n"),
            "   \n\t\n" + String(repeating: "spaced    out\t\twords   ", count: 40),
            "Café, naïve, 日本語のテキスト、そして絵文字 👩‍👩‍👧‍👦 " + String(repeating: "déjà vu ", count: 60),
            "> quoted\n>> nested\n1. first\n2) second\n" + String(repeating: "~~gone~~ __kept__ ", count: 40),
            // Lines that come to nothing, then a combining mark and flags either side of the limit.
            String(repeating: "**\n", count: 500) + String(repeating: "e\u{301}", count: 295) + "\n\u{301}x 🇯🇵🇺🇸 y",
            String(repeating: "🇯🇵", count: 299) + "\n🇺🇸 z",
        ]
    }()

    @Test(arguments: replies.indices)
    func readingPartOfAReplyMakesTheSamePreview(_ i: Int) {
        let reply = Self.replies[i]
        #expect(ThreadModel.plainPreview(reply) == wholeReply(reply))
        #expect(ThreadModel.plainPreview(reply, limit: 20) == wholeReply(reply, limit: 20))
    }
}
