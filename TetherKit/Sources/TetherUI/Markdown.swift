import SwiftUI

/// Block-level Markdown (fenced code, headings, lists, quotes, rules, tables, paragraphs) with
/// inline syntax via AttributedString.
struct MarkdownView: View {
    let text: String
    /// Parses once per text change rather than once per layout pass.
    @State private var cache = MarkdownCache()

    enum Block: Hashable {
        case code(lang: String, body: String)
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, marker: String, text: String)
        case quote(String)
        case rule
        case table([[String]])
    }

    var body: some View {
        // A block that appears after the first draw arrived while the reply streamed.
        let arriving = cache.hasDrawn
        let blocks = cache.blocks(for: text)
        let _ = cache.hasDrawn = true
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { i in
                MarkdownBlockView(rendered: blocks[i],
                                  topPadding: i == 0 ? 0 : Self.spacing(after: blocks[i - 1].block, before: blocks[i].block),
                                  isEnd: i == blocks.count - 1, arrives: arriving)
                    .equatable()
            }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
        .scaledFont(.body)
    }

    /// One parsed block and its inline text, parsed once. `id` changes only when the block is parsed
    /// again, so a settled block of a streaming message compares equal from frame to frame.
    struct Rendered {
        let id: Int
        let block: Block
        let inline: [AttributedString]
    }

    /// List items sit closer together than paragraphs.
    private static func spacing(after previous: Block, before block: Block) -> CGFloat {
        if case .bullet = previous, case .bullet = block { return 6 }
        return 12
    }

    /// The text without Markdown's syntax, as Copy puts it on the pasteboard: emphasis, links and
    /// inline code resolved, heading markers and code fences dropped, line structure kept.
    static func plainText(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { return nil }
            var content = line
            if let heading = trimmed.firstMatch(of: /^#{1,6}\s+(.*)$/) { content = String(heading.1) }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: content, options: options)).map { String($0.characters) } ?? content
        }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var lines = text.components(separatedBy: "\n")[...]
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(joinSoftBreaks(para))) }
            para.removeAll()
        }
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let lang = String(trimmed.dropFirst(3))
                var body: [String] = []
                while let l = lines.popFirst() {
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(l)
                }
                blocks.append(.code(lang: lang, body: body.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let m = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(level: m.1.count, text: String(m.2)))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows: [[String]] = [cells(trimmed)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    lines.removeFirst()
                    let t = next.trimmingCharacters(in: .whitespaces)
                    if t.allSatisfy({ "|-: ".contains($0) }) { continue }
                    rows.append(cells(t))
                }
                blocks.append(.table(rows))
            } else if let m = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                let marker = m.2 == "-" || m.2 == "*" || m.2 == "+" ? "•" : String(m.2)
                blocks.append(.bullet(indent: m.1.count / 2, marker: marker, text: String(m.3)))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        flush()
        return blocks
    }

    /// A single newline inside a paragraph is a space, as in CommonMark; a line ending in two
    /// spaces or a backslash keeps its break.
    private static func joinSoftBreaks(_ lines: [String]) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            guard i < lines.count - 1 else { out += line; break }
            if line.hasSuffix("  ") || line.hasSuffix("\\") {
                out += line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\\")) + "\n"
            } else {
                out += line.trimmingCharacters(in: .whitespaces) + " "
            }
        }
        return out
    }

    private static func cells(_ row: String) -> [String] {
        row.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// One Markdown block. Equal to its last value while the block wasn't parsed again, so a
/// streaming message redraws only its growing tail, not every block before it.
struct MarkdownBlockView: View, Equatable {
    let rendered: MarkdownView.Rendered
    let topPadding: CGFloat
    /// The last block, the only one streamed text is added to: its new text fades in.
    var isEnd = false
    /// Whether the block appeared while its reply streamed, so its first text fades in too.
    var arrives = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.rendered.id == b.rendered.id && a.topPadding == b.topPadding && a.isEnd == b.isEnd && a.arrives == b.arrives
    }

    var body: some View {
        content.padding(.top, topPadding)
    }

    private func inline(_ i: Int) -> Text {
        i < rendered.inline.count ? Text(rendered.inline[i]) : Text(verbatim: "")
    }

    /// A block's text, fading in as it arrives when it's the block being streamed into.
    @ViewBuilder private var line: some View {
        if isEnd, let text = rendered.inline.first {
            ArrivingText(text: text, arrives: arrives)
        } else {
            inline(0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch rendered.block {
        case .code(let lang, let body):
            CodeBlock(code: body, language: lang, streams: isEnd, arrives: arrives)
        case .heading(let level, _):
            line.scaledFont(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold)
                .padding(.top, 6)
                // So VoiceOver's headings rotor steps through a long reply.
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(level == 1 ? .h1 : level == 2 ? .h2 : level == 3 ? .h3 : .h4)
        case .paragraph:
            line
        case .bullet(let indent, let marker, _):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 12, alignment: .trailing)
                line
            }
            .padding(.leading, 6 + CGFloat(indent) * 18)
        case .quote:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                line.foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        case .table(let rows):
            let columns = rows.first?.count ?? 0
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(0..<rows[r].count, id: \.self) { c in
                            inline(r * columns + c).scaledFont(.body, weight: r == 0 ? .bold : nil)
                        }
                    }
                    if r == 0 { Divider() }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Remembers the last parse for one message, and reuses the finished blocks of a message that is
/// still streaming: new text only ever arrives at the end, so everything before the last blank
/// line outside a code fence is settled and isn't parsed again. Per token the work is the size of
/// the unsettled tail, not of the message: lengths are compared in UTF-8 bytes rather than counted in
/// Characters, and the settled boundary is found by scanning only what arrived since the last call.
@MainActor
final class MarkdownCache {
    /// Whether the view has drawn once: blocks that appear after that arrived as the reply streamed.
    var hasDrawn = false
    private var text = ""
    private var blocks: [MarkdownView.Rendered] = []
    /// UTF-8 length of the settled prefix, and its blocks.
    private var settledLength = 0
    private var settledBlocks: [MarkdownView.Rendered] = []
    /// Where the boundary scan stopped, whether a code fence was open there, and whether the line
    /// before it was blank.
    private var scannedLength = 0
    private var fenceOpen = false
    private var previousLineBlank = false
    /// App-wide, so a block reused from `recent` never shares an id with one parsed here.
    private static var nextID = 0
    /// Whole messages as a new view first saw them. A view is made again when its chat is reopened
    /// or its row scrolls back into view; this spares it parsing the message on that frame.
    private static var recent: [String: [MarkdownView.Rendered]] = [:]
    private static var recentOrder: [String] = []
    /// The unsettled tail's blocks from the last call: a block whose text didn't change keeps its
    /// render, so it isn't parsed again and its view compares equal.
    private var tailBlocks: [MarkdownView.Rendered] = []

    func blocks(for newText: String) -> [MarkdownView.Rendered] {
        if newText.utf8.count == text.utf8.count, newText == text { return blocks }
        if text.isEmpty, let known = Self.recent[newText] {
            // A fresh view of a message parsed before; streaming, if any, continues from here.
            text = newText
            blocks = known
            tailBlocks = known
            settledLength = 0
            settledBlocks = []
            scannedLength = 0
            return blocks
        }
        let isFirst = text.isEmpty
        let appended = newText.utf8.count >= scannedLength
            && newText.utf8.prefix(scannedLength).elementsEqual(text.utf8.prefix(scannedLength))
        if !appended { reset() }
        text = newText
        advanceSettledPrefix()
        let tail = String(decoding: text.utf8.dropFirst(settledLength), as: UTF8.self)
        let previous = tailBlocks
        tailBlocks = MarkdownView.parse(tail).enumerated().map { i, block in
            i < previous.count && previous[i].block == block ? previous[i] : render(block)
        }
        blocks = settledBlocks + tailBlocks
        if isFirst { Self.remember(newText, blocks) }
        return blocks
    }

    private func reset() {
        tailBlocks = []
        settledLength = 0
        settledBlocks = []
        scannedLength = 0
        fenceOpen = false
        previousLineBlank = false
    }

    private func render(_ block: MarkdownView.Block) -> MarkdownView.Rendered {
        Self.nextID += 1
        return MarkdownView.Rendered(id: Self.nextID, block: block, inline: block.inlineText.map(Self.inline))
    }

    private static func remember(_ text: String, _ blocks: [MarkdownView.Rendered]) {
        guard recent[text] == nil else { return }
        recent[text] = blocks
        recentOrder.append(text)
        if recentOrder.count > 400 { recent[recentOrder.removeFirst()] = nil }
    }

    /// Moves the settled boundary to the last blank line outside a code fence, scanning only the
    /// complete lines that arrived since the last call.
    private func advanceSettledPrefix() {
        let utf8 = text.utf8
        guard utf8.count > 2048 else { return } // short messages aren't worth tracking
        let newline = UInt8(ascii: "\n"), backtick = UInt8(ascii: "`")
        var boundary: Int?
        var lineStart = scannedLength
        var lineLength = 0
        var lineIsBlank = true
        var startsWithFence = true
        var offset = scannedLength
        for byte in utf8.dropFirst(scannedLength) {
            if byte == newline {
                if lineLength >= 3, startsWithFence { fenceOpen.toggle() }
                if lineIsBlank, !previousLineBlank, !fenceOpen { boundary = lineStart }
                previousLineBlank = lineIsBlank
                lineStart = offset + 1
                lineLength = 0
                lineIsBlank = true
                startsWithFence = true
            } else {
                if lineLength < 3, byte != backtick { startsWithFence = false }
                if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t"), byte != UInt8(ascii: "\r") { lineIsBlank = false }
                lineLength += 1
            }
            offset += 1
        }
        scannedLength = lineStart
        guard let boundary, boundary > settledLength else { return }
        let newlySettled = String(decoding: utf8.dropFirst(settledLength).prefix(boundary - settledLength), as: UTF8.self)
        // Blocks that were the tail's until now keep their render as they settle.
        let parsed = MarkdownView.parse(newlySettled)
        settledBlocks += parsed.enumerated().map { i, block in
            i < tailBlocks.count && tailBlocks[i].block == block ? tailBlocks[i] : render(block)
        }
        tailBlocks = Array(tailBlocks.dropFirst(parsed.count))
        settledLength = boundary
    }

    /// Inline Markdown as an attributed string, styled for the transcript.
    static func inline(_ text: String) -> AttributedString {
        guard var value = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        style(&value)
        return value
    }

    /// Inline code on a faint fill, in the text's own color: red already means a failure or a risky
    /// permission elsewhere. Text draws the code and strong runs monospaced and bold itself, so they
    /// take the surrounding size, whatever View ▸ Bigger or Smaller has made it.
    private static func style(_ value: inout AttributedString) {
        let ranges = value.runs.compactMap { run -> (Range<AttributedString.Index>, InlinePresentationIntent)? in
            run.inlinePresentationIntent.map { (run.range, $0) }
        }
        for (range, intent) in ranges {
            if intent.contains(.code) {
                value[range].backgroundColor = Color.primary.opacity(0.08)
            }
        }
    }
}

extension MarkdownView.Block {
    var inlineText: [String] {
        switch self {
        case .heading(_, let text), .paragraph(let text), .bullet(_, _, let text), .quote(let text):
            [text]
        case .table(let rows):
            rows.flatMap { $0 }
        case .code, .rule:
            []
        }
    }
}

/// Monospaced block that wraps and sizes itself; long output collapses to `lineLimit` lines.
struct CodeBlock: View {
    let code: String
    var language: String = ""
    var lineLimit: Int? = nil
    /// Whether it's being streamed into, and appeared while it was: as `MarkdownBlockView`'s.
    var streams = false
    var arrives = false
    @State private var expanded = false
    @Environment(\.appearance) private var appearance

    @ViewBuilder private var codeText: some View {
        if streams {
            ArrivingText(text: AttributedString(code), arrives: arrives)
        } else {
            Text(verbatim: code)
        }
    }

    private func styled(_ text: some View) -> some View {
        text
            .scaledFont(.callout, design: .monospaced)
            .lineLimit(expanded ? nil : lineLimit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineCount: Int { code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var isTruncated: Bool { lineLimit.map { lineCount > $0 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                Spacer()
                if isTruncated {
                    Button(expanded ? "Show Less" : "Show All \(lineCount) Lines") { expanded.toggle() }
                        .buttonStyle(.link)
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 8))
    }
}

#if DEBUG
#Preview("Markdown") {
    ScrollView {
        MarkdownView(text: sampleMarkdownPreviewText)
            .padding(20)
    }
    .frame(width: 480, height: 420)
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
- `#Preview` support across every `TetherUI` view
- Faster reconnect after the daemon restarts

**Cause.** On attach, the app's only source of settings is the `thread` object returned by
`thread/subscribe`, so the toolbar fell back to *your* defaults.

1. Read the tail of the transcript
2. Skip subagent turns

Run the tests with:

```swift
swift test --filter ThreadModelTests
```

> Transcript content stays on standard fills — glass is reserved for the controls layer.
"""

#endif
