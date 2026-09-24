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
        let blocks = cache.blocks(for: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(for: block)
                    .padding(.top, i == 0 ? 0 : Self.spacing(after: blocks[i - 1], before: block))
            }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .code(let lang, let body):
            CodeBlock(code: body, language: lang)
        case .heading(let level, let text):
            inline(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 6)
        case .paragraph(let text):
            inline(text)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 12, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, 6 + CGFloat(indent) * 18)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(i == 0 ? .body.bold() : .body)
                        }
                    }
                    if i == 0 { Divider() }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// List items sit closer together than paragraphs.
    private static func spacing(after previous: Block, before block: Block) -> CGFloat {
        if case .bullet = previous, case .bullet = block { return 6 }
        return 12
    }

    private func inline(_ s: String) -> Text {
        if let a = cache.inline(for: s) {
            return Text(a)
        }
        return Text(s)
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

/// Remembers the last parse for one message, and reuses the finished blocks of a message that is
/// still streaming: new text only ever arrives at the end, so everything before the last blank
/// line outside a code fence is already settled and doesn't need parsing again.
@MainActor
final class MarkdownCache {
    private var text = ""
    private var blocks: [MarkdownView.Block] = []
    private var settledText = ""
    private var settledBlocks: [MarkdownView.Block] = []
    /// Inline parses for the current blocks only, so streaming doesn't leave one per token.
    private var inlineValues: [String: AttributedString] = [:]

    func blocks(for newText: String) -> [MarkdownView.Block] {
        if newText == text { return blocks }
        if !settledText.isEmpty, newText.hasPrefix(settledText) {
            blocks = settledBlocks + MarkdownView.parse(String(newText.dropFirst(settledText.count)))
        } else {
            blocks = MarkdownView.parse(newText)
            settledText = ""
            settledBlocks = []
        }
        text = newText
        let currentInlineText = Set(blocks.flatMap(\.inlineText))
        inlineValues = inlineValues.filter { currentInlineText.contains($0.key) }
        updateSettledPrefix()
        return blocks
    }

    func inline(for text: String) -> AttributedString? {
        if let value = inlineValues[text] { return value }
        guard var value = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        Self.style(&value)
        inlineValues[text] = value
        return value
    }

    /// Inline code as a tinted monospaced run on a faint fill; bold a touch heavier than the
    /// default so it reads as emphasis in body text.
    private static func style(_ value: inout AttributedString) {
        let ranges = value.runs.compactMap { run -> (Range<AttributedString.Index>, InlinePresentationIntent)? in
            run.inlinePresentationIntent.map { (run.range, $0) }
        }
        for (range, intent) in ranges {
            if intent.contains(.code) {
                value[range].font = .system(.callout, design: .monospaced)
                value[range].foregroundColor = Color.inlineCode
                value[range].backgroundColor = Color.primary.opacity(0.07)
            } else if intent.contains(.stronglyEmphasized) {
                value[range].font = .body.weight(.semibold)
            }
        }
    }

    /// The prefix up to the last blank line that isn't inside an open code fence.
    private func updateSettledPrefix() {
        guard text.count > 2048 else { return } // not worth tracking for short messages
        var fenceCount = 0
        var lastBoundary: String.Index?
        var previousWasBlank = false
        var lineStart = text.startIndex
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { fenceCount += 1 }
            let isBlank = line.allSatisfy(\.isWhitespace)
            if isBlank, !previousWasBlank, fenceCount.isMultiple(of: 2) { lastBoundary = lineStart }
            previousWasBlank = isBlank
            lineStart = text.index(lineStart, offsetBy: line.count + 1, limitedBy: text.endIndex) ?? text.endIndex
        }
        guard let boundary = lastBoundary, boundary > text.startIndex else { return }
        let prefix = String(text[text.startIndex..<boundary])
        guard prefix != settledText else { return }
        settledText = prefix
        settledBlocks = MarkdownView.parse(prefix)
    }
}

private extension MarkdownView.Block {
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

extension Color {
    /// Inline code: a muted red that holds contrast in both appearances.
    static let inlineCode = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.93, green: 0.49, blue: 0.47, alpha: 1)
            : NSColor(srgbRed: 0.75, green: 0.22, blue: 0.20, alpha: 1)
    })
}

/// Monospaced block that wraps and sizes itself; long output collapses to `lineLimit` lines.
struct CodeBlock: View {
    let code: String
    var language: String = ""
    var lineLimit: Int? = nil
    @State private var expanded = false

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
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(expanded ? nil : lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
