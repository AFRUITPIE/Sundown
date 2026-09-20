import SwiftUI

/// Lightweight block-level Markdown: fenced code, headings, lists, quotes, rules, paragraphs
/// (inline syntax via AttributedString). Good enough for Claude's output without a dependency.
struct MarkdownView: View {
    let text: String
    /// Parsing is pure but not cheap (a regex pass per line), and the same text is rendered again
    /// on every layout — dragging the sidebar open re-parses every visible message per frame. The
    /// cache is @State, so it lives as long as the row does and survives those re-renders.
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cache.blocks(for: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .code(let lang, let body):
            CodeBlock(code: body, language: lang)
        case .heading(let level, let text):
            inline(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            inline(text)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
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

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var lines = text.components(separatedBy: "\n")[...]
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
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
        updateSettledPrefix()
        return blocks
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

Run the tests with:

```swift
swift test --filter ThreadModelTests
```

> Transcript content stays on standard fills — glass is reserved for the controls layer.
"""

#endif
