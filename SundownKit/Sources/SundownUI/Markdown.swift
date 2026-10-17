import SwiftUI

/// A message's Markdown (CommonMark and GitHub's tables, task lists and strikethrough, parsed by
/// swift-markdown: `MarkdownParsing.swift`), drawn as one selectable text (`MarkdownTextView`).
struct MarkdownView: View {
    let text: String
    /// Whether this is the reply being streamed into: only then does new text fade in. Every
    /// settled reply, and every other use, draws its text at once.
    var streams = false
    /// A reply's colors, or a prompt's in its bubble.
    var style: MarkdownStyle = .reply
    /// Parses once per text change rather than once per layout pass.
    @State private var cache = MarkdownCache()

    /// One block as it's drawn. `indent`: how many list items it's inside, its text lined up with
    /// theirs (an item's own `indent` is its depth). Inline text is Foundation's: presentation
    /// intents and links, which `MarkdownBuilder` gives fonts and colors.
    enum Block: Hashable {
        case code(lang: String, body: String, indent: Int = 0)
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString, indent: Int = 0)
        /// `marker`: "•", or an ordered list's number ("3."). `task`: a task list's item, done or not.
        case bullet(indent: Int, marker: String, task: Bool? = nil, text: AttributedString)
        case quote(AttributedString, indent: Int = 0)
        case rule
        /// The header row first; a column's alignment, as its delimiter row gives it.
        case table([[AttributedString]], alignments: [ColumnAlignment] = [])
    }

    enum ColumnAlignment: Hashable {
        case natural, left, center, right
    }

    var body: some View {
        MarkdownTextView(blocks: cache.blocks(for: text, streaming: streams, lineBreaks: style == .prompt),
                         style: style, streams: streams, source: text)
    }

    /// One parsed block, given an id once. `id` changes only when the block is parsed again
    /// differently, so a settled block of a streaming message compares equal from frame to frame.
    struct Rendered {
        let id: Int
        let block: Block
    }

    /// For each list item, the widest marker among the items of its list at its depth ("10." in a
    /// list that reaches ten), so their text starts at one edge; for what's inside an item (its
    /// paragraphs after the first, its code), its item's, so it lines up with the item's text; nil
    /// for other blocks.
    static func widestMarkers(_ blocks: [Rendered]) -> [String?] {
        var result = [String?](repeating: nil, count: blocks.count)
        var i = 0
        while i < blocks.count {
            guard blocks[i].block.listDepth != nil else { i += 1; continue }
            var end = i
            while end < blocks.count, blocks[end].block.listDepth != nil { end += 1 }
            var widest: [Int: String] = [:]
            for case .bullet(let indent, let marker, _, _) in blocks[i..<end].map(\.block)
            where marker.count > (widest[indent]?.count ?? 0) {
                widest[indent] = marker
            }
            for j in i..<end {
                switch blocks[j].block {
                case .bullet(let indent, _, _, _): result[j] = widest[indent]
                default: result[j] = blocks[j].block.listDepth.flatMap { widest[$0 - 1] } ?? "•"
                }
            }
            i = end
        }
        return result
    }

    /// The text without Markdown's syntax, as Copy puts it on the pasteboard: emphasis, links and
    /// inline code resolved, heading markers and code fences dropped, line structure kept.
    static func plainText(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { return nil }
            var content = line
            if trimmed.first == "#", let heading = trimmed.firstMatch(of: headingPattern) { content = String(heading.2) }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: content, options: options)).map { String($0.characters) } ?? content
        }.joined(separator: "\n")
    }

    /// Made once: a regex literal in the loop above made, and compiled, a new one for every line.
    /// `Regex` isn't `Sendable`, but it compiles its program once, atomically, and only reads it
    /// after, so calls off the main actor can share it.
    nonisolated(unsafe) private static let headingPattern = /^(#{1,6})\s+(.*)$/
}

/// Remembers the last parse for one message, and reuses the finished blocks of a message that is
/// still streaming: new text only ever arrives at the end, and every top-level element but the
/// last is finished whatever follows it (a list's next item, a fence's close or a paragraph's next
/// line all belong to the last), so the text before the last one's first line is settled and isn't
/// parsed again. Per token the work is the size of that last element, not of the message.
@MainActor
final class MarkdownCache {
    private var text = ""
    private var blocks: [MarkdownView.Rendered] = []
    /// Whether these are a prompt's blocks (`blocks(for:streaming:lineBreaks:)`).
    private var lineBreaks = false
    /// Whether this view has put its message in `recent`, which it does once, when it isn't streaming.
    private var remembered = false
    /// UTF-8 length of the settled prefix, and its blocks.
    private(set) var settledLength = 0
    private var settledBlocks: [MarkdownView.Rendered] = []
    /// Whether the last parse left out a last line that could still make the paragraph above it a
    /// heading (`undecidedLine`).
    private var heldBack = false
    /// App-wide, so a block reused from `recent` never shares an id with one parsed here.
    private static var nextID = 0
    /// Whole messages as views saw them once settled, and prewarmed ones. A view is made again
    /// when its chat is reopened or its row scrolls back into view; this spares it parsing the
    /// message on that frame.
    static let recent = RecentParses()
    /// The unsettled tail's blocks from the last call: a block whose text didn't change keeps its
    /// render, so its view compares equal.
    private var tailBlocks: [MarkdownView.Rendered] = []

    /// `streaming`: the message is still arriving, so this text isn't remembered in `recent`: each
    /// length of it was a key never looked up again.
    /// `lineBreaks`: a prompt's, whose every newline in a paragraph is a break (`parse`). Its
    /// parses aren't shared in `recent`, which holds replies': a prompt is short, and parsed once.
    func blocks(for newText: String, streaming: Bool = false, lineBreaks: Bool = false) -> [MarkdownView.Rendered] {
        if lineBreaks != self.lineBreaks {
            self.lineBreaks = lineBreaks
            text = ""
            blocks = []
            remembered = false
            reset()
        }
        if newText.utf8.count == text.utf8.count, newText == text, !(heldBack && !streaming) {
            rememberOnce(streaming: streaming)
            return blocks
        }
        if text.isEmpty, !lineBreaks, let known = Self.recent.blocks(for: newText) {
            // A fresh view of a message parsed before; streaming, if any, continues from here.
            text = newText
            blocks = known
            tailBlocks = known
            settledLength = 0
            settledBlocks = []
            heldBack = false
            remembered = true
            return blocks
        }
        let appended = newText.utf8.count >= settledLength
            && newText.utf8.prefix(settledLength).elementsEqual(text.utf8.prefix(settledLength))
        if !appended { reset() }
        text = newText
        var tail = String(decoding: text.utf8.dropFirst(settledLength), as: UTF8.self)
        heldBack = false
        if streaming, let line = Self.undecidedLine(tail) {
            tail = String(tail[..<line])
            heldBack = true
        }
        let elements = MarkdownView.parseTopLevel(tail, lineBreaks: lineBreaks)
        let previous = tailBlocks
        var parsed = elements.flatMap(\.blocks).enumerated().map { i, block in
            i < previous.count && previous[i].block == block ? previous[i] : Self.render(block)
        }
        // Short messages aren't worth tracking.
        if text.utf8.count > 2048, elements.count > 1, let last = elements.last, let line = last.line,
           let offset = Self.offset(ofLine: line, in: tail) {
            let settled = parsed.count - last.blocks.count
            settledBlocks += parsed.prefix(settled)
            parsed.removeFirst(settled)
            settledLength += offset
        }
        tailBlocks = parsed
        blocks = settledBlocks + tailBlocks
        rememberOnce(streaming: streaming)
        return blocks
    }

    /// The message as it is once it has stopped arriving: the first text a settled reply's view
    /// sees, or a streamed reply's last.
    private func rememberOnce(streaming: Bool) {
        guard !streaming, !remembered, !lineBreaks else { return }
        remembered = true
        Self.recent.remember(text, blocks)
    }

    private func reset() {
        tailBlocks = []
        settledLength = 0
        settledBlocks = []
        heldBack = false
    }

    private static func render(_ block: MarkdownView.Block) -> MarkdownView.Rendered {
        nextID += 1
        return MarkdownView.Rendered(id: nextID, block: block)
    }

    /// Where an unfinished last line of only `-` or `=` starts: under a paragraph it makes the
    /// paragraph a heading, though it's usually the start of a list item or a rule, so a streaming
    /// reply waits for what comes next rather than showing a heading for a frame.
    private static func undecidedLine(_ text: String) -> String.Index? {
        let start = text.lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
        let line = text[start...].drop { $0 == " " }
        guard let first = line.first, first == "-" || first == "=", line.allSatisfy({ $0 == first }) else { return nil }
        return start
    }

    /// The UTF-8 offset at which a line (from 1) starts, lines ending as cmark ends them: at "\n",
    /// "\r\n" or "\r".
    private static func offset(ofLine line: Int, in text: String) -> Int? {
        guard line > 1 else { return line == 1 ? 0 : nil }
        let utf8 = text.utf8
        var current = 1
        var offset = 0
        var i = utf8.startIndex
        while i != utf8.endIndex {
            let byte = utf8[i]
            utf8.formIndex(after: &i)
            offset += 1
            let ends = byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r") && (i == utf8.endIndex || utf8[i] != UInt8(ascii: "\n"))
            guard ends else { continue }
            current += 1
            if current == line { return offset }
        }
        return nil
    }

    /// Parses messages off the main actor and remembers them, so their rows find them parsed: a
    /// chat opening, or an older page going in above the reader, otherwise parsed each reply in
    /// its row's body on the main thread. Ids are given here, on the main actor, as every block's
    /// are. Pass a page of replies, not a whole long chat's: what's remembered is bounded.
    static func prewarm(_ texts: [String]) async {
        var seen = Set<String>()
        let fresh = texts.filter { !recent.contains($0) && seen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        let parsed = await parseAll(fresh)
        for (text, blocks) in zip(fresh, parsed) where !recent.contains(text) {
            recent.remember(text, blocks.map(render))
        }
    }

    /// Each message's blocks, stopping early if the caller has gone.
    @concurrent
    private nonisolated static func parseAll(_ texts: [String]) async -> [[MarkdownView.Block]] {
        var out: [[MarkdownView.Block]] = []
        for text in texts {
            if Task.isCancelled { break }
            out.append(MarkdownView.parse(text))
        }
        return out
    }
}

/// Parses of whole messages, for views made again and messages prewarmed. Bounded by count and by
/// the messages' size, a long chat's replies being megabytes; the least recently used go first.
@MainActor
final class RecentParses {
    private struct Entry {
        let blocks: [MarkdownView.Rendered]
        let bytes: Int
        var lastUse: Int
    }

    private var entries: [String: Entry] = [:]
    private var clock = 0
    /// The remembered messages' UTF-8 lengths, summed.
    private(set) var bytes = 0
    let maxCount: Int
    let maxBytes: Int

    init(maxCount: Int = 400, maxBytes: Int = 4 << 20) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    var count: Int { entries.count }

    func contains(_ text: String) -> Bool { entries[text] != nil }

    /// A remembered message's blocks, which makes it the most recently used.
    func blocks(for text: String) -> [MarkdownView.Rendered]? {
        guard let i = entries.index(forKey: text) else { return nil }
        clock += 1
        entries.values[i].lastUse = clock
        return entries.values[i].blocks
    }

    func remember(_ text: String, _ blocks: [MarkdownView.Rendered]) {
        let size = text.utf8.count
        // A message that alone takes much of the budget would push out everything else.
        guard size <= maxBytes / 4 else { return }
        clock += 1
        if let i = entries.index(forKey: text) {
            entries.values[i].lastUse = clock
            return
        }
        entries[text] = Entry(blocks: blocks, bytes: size, lastUse: clock)
        bytes += size
        while entries.count > maxCount || bytes > maxBytes, let oldest = entries.indices.min(by: {
            entries.values[$0].lastUse < entries.values[$1].lastUse
        }) {
            bytes -= entries.values[oldest].bytes
            entries.remove(at: oldest)
        }
    }
}

extension MarkdownView.Block {
    /// How many list items it's inside, an item's own depth for an item; nil outside lists.
    var listDepth: Int? {
        switch self {
        case .bullet(let indent, _, _, _): indent
        case .paragraph(_, let indent), .quote(_, let indent), .code(_, _, let indent): indent > 0 ? indent : nil
        case .heading, .rule, .table: nil
        }
    }
}

/// Monospaced block that wraps and sizes itself; long output collapses to `lineLimit` lines.
struct CodeBlock: View {
    let code: String
    var language: String = ""
    var lineLimit: Int? = nil
    @State private var expanded = false
    /// The shown code in color, once it has been scanned off the main actor.
    @State private var colored: (source: String, text: AttributedString)?
    @Environment(\.appearance) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast

    private func styled(_ text: some View) -> some View {
        text
            .scaledFont(.callout, design: .monospaced)
            .foregroundStyle(.primary)
            .lineLimit(expanded ? nil : lineLimit)
            .textSelection(.enabled)
            // Read as code, punctuation and all.
            .accessibilityTextContentType(.sourceCode)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How many lines the code has, and, when it has more than `limit` and one, where its first
    /// `limit` and one end. Collapsed, only those are drawn: a tool's output can be megabytes, and
    /// Text laid all of it out to show 14 lines. The one past the limit keeps the last line shown
    /// ending in an ellipsis, as it did. One pass over the bytes, not two over the Characters.
    nonisolated static func measure(_ code: String, limit: Int?) -> (lines: Int, collapsedEnd: String.Index?) {
        let utf8 = code.utf8
        var lines = 1
        var end: String.Index?
        var i = utf8.startIndex
        while i != utf8.endIndex {
            if utf8[i] == UInt8(ascii: "\n") {
                if let limit, lines == limit + 1 { end = i }
                lines += 1
            }
            utf8.formIndex(after: &i)
        }
        return (lines, end)
    }

    var body: some View {
        let measure = Self.measure(code, limit: lineLimit)
        let isTruncated = lineLimit.map { measure.lines > $0 } ?? false
        let shown = !expanded ? measure.collapsedEnd.map { String(code[..<$0]) } ?? code : code
        // Plain until its colors are ready: only the colors change, never the layout.
        let codeText = colored.flatMap { $0.source == shown ? Text($0.text) : nil }
            ?? SyntaxHighlight.cached(shown, language: language).map(Text.init)
            ?? Text(verbatim: shown)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .fontWeight(.medium)
                Spacer()
                if isTruncated {
                    Button(expanded ? "Show Less" : "Show All \(measure.lines) Lines") { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("code.expand")
                }
                CopyButton { Clipboard.copy(code) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("code.copy")
            }
            .scaledFont(.caption, design: .default)
            .foregroundStyle(.secondary)
            // The header drags the code out, as text; the code itself stays selectable.
            .draggable(code)
            if appearance.wrapCode {
                styled(codeText)
            } else {
                // Unwrapped, a long line scrolls sideways: its own width, not the column's.
                ScrollView(.horizontal) {
                    styled(codeText.fixedSize(horizontal: true, vertical: false))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .controlSize(.regular)
        .padding(12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.12))
                .allowsHitTesting(false)
        }
        .task(id: shown) {
            guard colored?.source != shown, let text = await SyntaxHighlight.highlight(shown, language: language),
                  !Task.isCancelled else { return }
            colored = (shown, text)
        }
    }
}

#if DEBUG
#Preview("Markdown") {
    ScrollView {
        MarkdownView(text: sampleMarkdownPreviewText)
            .padding(20)
    }
    .frame(width: 480, height: 900)
}

#Preview("Code block") {
    CodeBlock(code: """
    case .itemAgentMessageDelta(let e):
        mutate(e.itemId) { if case .agentMessage(var m) = $0 { m.text += e.delta } }
    """, language: "swift")
        .padding(20)
        .frame(width: 460)
}

#Preview("Code block (truncated)") {
    CodeBlock(code: (1...30).map { "line \($0) of output" }.joined(separator: "\n"), language: "output", lineLimit: 8)
        .padding(20)
        .frame(width: 420)
}

private let sampleMarkdownPreviewText = """
# Release notes

## What's new

- Native **Liquid Glass** controls for the composer and prompt cards
- `#Preview` support across every `SundownUI` view
- Faster reconnect after the daemon restarts

**Cause.** On attach, the app's only source of settings is the `thread` object returned by
`thread/subscribe`, so the toolbar fell back to *your* defaults.

1. Read the tail of the transcript
2. Skip subagent turns

Run the tests with:

```swift
swift test --filter ThreadModelTests
```

> Transcript content stays on standard fills — glass is reserved for the controls layer, and a long quote wraps under itself.

- [x] Parse blocks off the main actor
- [ ] Select across every block
  - Nested items hang under their own text when they wrap onto a second line
    - And nest again

9. Ninth, holding code:

   ```sh
   swift test --package-path SundownKit
   ```

   And a second paragraph, lined up with the item's text.
10. Tenth, whose marker is wider

| Option | Effect | Default |
|---|---|--:|
| `wrapCode` | Wraps long lines | On |
| Reading width | Narrow, Medium or Wide | Narrow |

---

See [Apple's documentation](https://developer.apple.com/documentation/swiftui) for more.
"""

#endif
