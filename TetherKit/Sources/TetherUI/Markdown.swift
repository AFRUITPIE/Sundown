import SwiftUI

/// Block-level Markdown (fenced code, headings, lists, quotes, rules, tables, paragraphs) with
/// inline syntax via AttributedString.
struct MarkdownView: View {
    let text: String
    /// Whether this is the reply being streamed into: only then does its last block fade new text
    /// in (`ArrivingText`). Every settled reply, and every other use, draws plain text.
    var streams = false
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
        let blocks = cache.blocks(for: text, streaming: streams)
        let _ = cache.hasDrawn = true
        let markers = Self.widestMarkers(blocks)
        BlockStack {
            ForEach(blocks.indices, id: \.self) { i in
                MarkdownBlockView(rendered: blocks[i],
                                  topPadding: i == 0 ? 0 : Self.spacing(after: blocks[i - 1].block, before: blocks[i].block),
                                  isEnd: streams && i == blocks.count - 1, arrives: streams && arriving,
                                  widestMarker: markers[i])
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

    /// For each list item, the widest marker among the items of its list at its depth ("10." in a
    /// list that reaches ten), so their text starts at one edge; nil for other blocks.
    static func widestMarkers(_ blocks: [Rendered]) -> [String?] {
        var result = [String?](repeating: nil, count: blocks.count)
        var i = 0
        while i < blocks.count {
            guard case .bullet = blocks[i].block else { i += 1; continue }
            var end = i
            while end < blocks.count, case .bullet = blocks[end].block { end += 1 }
            var widest: [Int: String] = [:]
            for case .bullet(let indent, let marker, _) in blocks[i..<end].map(\.block)
            where marker.count > (widest[indent]?.count ?? 0) {
                widest[indent] = marker
            }
            for j in i..<end {
                if case .bullet(let indent, _, _) = blocks[j].block { result[j] = widest[indent] }
            }
            i = end
        }
        return result
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
            if trimmed.first == "#", let heading = trimmed.firstMatch(of: headingPattern) { content = String(heading.2) }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: content, options: options)).map { String($0.characters) } ?? content
        }.joined(separator: "\n")
    }

    /// Made once: a regex literal in the loop below made, and compiled, a new one for every line.
    /// `Regex` isn't `Sendable`, but it compiles its program once, atomically, and only reads it
    /// after, so parses off the main actor can share these.
    nonisolated(unsafe) private static let headingPattern = /^(#{1,6})\s+(.*)$/
    nonisolated(unsafe) private static let listItemPattern = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/

    /// Whether a line could be a list item: after its indent, a marker or a digit. Cheap, so the
    /// pattern runs only on lines that might match it. (`\s` is `isWhitespace` and `\d` is
    /// `isNumber`, so every line the pattern matches passes.)
    private nonisolated static func mightBeListItem(_ line: String) -> Bool {
        guard let c = line.first(where: { !$0.isWhitespace }) else { return false }
        return c == "-" || c == "*" || c == "+" || c.isNumber
    }

    /// Pure, so a page of history can be parsed off the main actor (`MarkdownCache.prewarm`).
    nonisolated static func parse(_ text: String) -> [Block] {
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
            } else if trimmed.first == "#", let m = trimmed.firstMatch(of: headingPattern) {
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
            } else if mightBeListItem(line), let m = line.firstMatch(of: listItemPattern) {
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
    private nonisolated static func joinSoftBreaks(_ lines: [String]) -> String {
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

    private nonisolated static func cells(_ row: String) -> [String] {
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
    /// The last block of the reply being streamed, the only one text is added to: its new text
    /// fades in. False for every block of a settled reply.
    var isEnd = false
    /// Whether the block appeared while its reply streamed, so its first text fades in too.
    var arrives = false
    /// A list item's widest sibling marker, whose width its own marker takes.
    var widestMarker: String?
    @Environment(\.textScale) private var textScale

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.rendered.id == b.rendered.id && a.topPadding == b.topPadding && a.isEnd == b.isEnd && a.arrives == b.arrives
            && a.widestMarker == b.widestMarker
    }

    var body: some View {
        // A stack, so every block is one view SwiftUI can count without building it.
        BlockStack { content }
            .padding(.top, topPadding)
    }

    private func inline(_ i: Int) -> Text {
        i < rendered.inline.count ? Text(rendered.inline[i]) : Text(verbatim: "")
    }

    /// A block's text, fading in as it arrives when it's the block being streamed into. A code
    /// block doesn't fade: it's monospaced output, read once it's there.
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
            CodeBlock(code: body, language: lang)
        case .heading(let level, _):
            line.scaledFont(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold)
                .padding(.top, 6)
                // So VoiceOver's headings rotor steps through a long reply.
                .accessibilityAddTraits(.isHeader)
                // A level under the dates, which head the chat's parts.
                .accessibilityHeading(level <= 1 ? .h2 : level == 2 ? .h3 : level == 3 ? .h4 : level == 4 ? .h5 : .h6)
        case .paragraph:
            line
        case .bullet(let indent, let marker, _):
            GutterLayout(spacing: 8) {
                // As wide as the list's widest marker, so "9." and "10." end at one edge.
                ZStack(alignment: .trailing) {
                    Text(widestMarker ?? marker).hidden()
                    Text(marker)
                }
                .frame(minWidth: 12, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                line
            }
            // Deeper levels step in by the text's size.
            .padding(.leading, (6 + CGFloat(indent) * 18) * textScale)
        case .quote:
            GutterLayout(spacing: 8, stretches: true) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                line.foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        case .table(let rows):
            let columns = rows.first?.count ?? 0
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let header = rows.first {
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { c in
                            inline(c).scaledFont(.body, weight: .bold)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    // Only as wide as the columns, so a narrow table hugs its content.
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                // One row per element, which lets SwiftUI count them without building each.
                ForEach(rows.indices.dropFirst(), id: \.self) { r in
                    GridRow {
                        ForEach(0..<rows[r].count, id: \.self) { c in
                            inline(r * columns + c).scaledFont(.body)
                        }
                    }
                }
            }
            .padding(8)
            .background(.fill.quinary, in: .rect(cornerRadius: 6))
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
    /// Whether this view has put its message in `recent`, which it does once, when it isn't streaming.
    private var remembered = false
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
    /// Whole messages as views saw them once settled, and prewarmed ones. A view is made again
    /// when its chat is reopened or its row scrolls back into view; this spares it parsing the
    /// message on that frame.
    static let recent = RecentParses()
    /// The unsettled tail's blocks from the last call: a block whose text didn't change keeps its
    /// render, so it isn't parsed again and its view compares equal.
    private var tailBlocks: [MarkdownView.Rendered] = []

    /// `streaming`: the message is still arriving, so this text isn't remembered in `recent`: each
    /// length of it was a key never looked up again.
    func blocks(for newText: String, streaming: Bool = false) -> [MarkdownView.Rendered] {
        if newText.utf8.count == text.utf8.count, newText == text {
            rememberOnce(streaming: streaming)
            return blocks
        }
        if text.isEmpty, let known = Self.recent.blocks(for: newText) {
            // A fresh view of a message parsed before; streaming, if any, continues from here.
            text = newText
            blocks = known
            tailBlocks = known
            settledLength = 0
            settledBlocks = []
            scannedLength = 0
            remembered = true
            return blocks
        }
        let appended = newText.utf8.count >= scannedLength
            && newText.utf8.prefix(scannedLength).elementsEqual(text.utf8.prefix(scannedLength))
        if !appended { reset() }
        text = newText
        advanceSettledPrefix()
        let tail = String(decoding: text.utf8.dropFirst(settledLength), as: UTF8.self)
        let previous = tailBlocks
        tailBlocks = MarkdownView.parse(tail).enumerated().map { i, block in
            i < previous.count && previous[i].block == block ? previous[i] : Self.render(block)
        }
        blocks = settledBlocks + tailBlocks
        rememberOnce(streaming: streaming)
        return blocks
    }

    /// The message as it is once it has stopped arriving: the first text a settled reply's view
    /// sees, or a streamed reply's last.
    private func rememberOnce(streaming: Bool) {
        guard !streaming, !remembered else { return }
        remembered = true
        Self.recent.remember(text, blocks)
    }

    private func reset() {
        tailBlocks = []
        settledLength = 0
        settledBlocks = []
        scannedLength = 0
        fenceOpen = false
        previousLineBlank = false
    }

    private static func render(_ block: MarkdownView.Block) -> MarkdownView.Rendered {
        render(block, inline: block.inlineText.map(inline))
    }

    private static func render(_ block: MarkdownView.Block, inline: [AttributedString]) -> MarkdownView.Rendered {
        nextID += 1
        return MarkdownView.Rendered(id: nextID, block: block, inline: inline)
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
            i < tailBlocks.count && tailBlocks[i].block == block ? tailBlocks[i] : Self.render(block)
        }
        tailBlocks = Array(tailBlocks.dropFirst(parsed.count))
        settledLength = boundary
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
            recent.remember(text, blocks.map { render($0.block, inline: $0.inline) })
        }
    }

    /// Each message's blocks and their inline text, stopping early if the caller has gone.
    @concurrent
    private nonisolated static func parseAll(_ texts: [String]) async -> [[(block: MarkdownView.Block, inline: [AttributedString])]] {
        var out: [[(block: MarkdownView.Block, inline: [AttributedString])]] = []
        for text in texts {
            if Task.isCancelled { break }
            out.append(MarkdownView.parse(text).map { ($0, $0.inlineText.map(inline)) })
        }
        return out
    }

    /// Inline Markdown as an attributed string, styled for the transcript.
    nonisolated static func inline(_ text: String) -> AttributedString {
        // Most blocks have no inline syntax at all, and the parser costs several times a plain string.
        guard mayHaveInlineSyntax(text) else { return AttributedString(text) }
        guard var value = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        style(&value)
        return value
    }

    /// Whether the text holds anything inline Markdown could change: emphasis, code, links, images,
    /// autolinks (a URL's colon, an address's @, "www."), HTML, entities, escapes, strikethrough, or
    /// a carriage return. Without any of them the parser gives back the text as it was.
    nonisolated static func mayHaveInlineSyntax(_ text: String) -> Bool {
        var ws = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: "!"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "&"), UInt8(ascii: "\\"),
                 UInt8(ascii: "~"), UInt8(ascii: ":"), UInt8(ascii: "@"), UInt8(ascii: "\r"):
                return true
            case UInt8(ascii: "w"), UInt8(ascii: "W"):
                ws += 1
            case UInt8(ascii: "."):
                if ws >= 3 { return true }
                ws = 0
            default:
                ws = 0
            }
        }
        return false
    }

    /// Inline code on a faint fill, in the text's own color: red already means a failure or a risky
    /// permission elsewhere. Text draws the code and strong runs monospaced and bold itself, so they
    /// take the surrounding size, whatever View ▸ Bigger or Smaller has made it.
    private nonisolated static func style(_ value: inout AttributedString) {
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
    @State private var expanded = false
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
        let codeText = Text(verbatim: !expanded ? measure.collapsedEnd.map { String(code[..<$0]) } ?? code : code)
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
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.bordered)
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
