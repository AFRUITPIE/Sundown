import SwiftUI

/// Lightweight block-level Markdown: fenced code, headings, lists, quotes, rules, paragraphs
/// (inline syntax via AttributedString). Good enough for Claude's output without a dependency.
struct MarkdownView: View {
    let text: String

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
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
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
            inline(text).fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text).fixedSize(horizontal: false, vertical: true)
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
