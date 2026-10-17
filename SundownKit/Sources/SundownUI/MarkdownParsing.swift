import Foundation
import Markdown

// A message's Markdown, read by swift-markdown (cmark-gfm: CommonMark, with GitHub's tables, task
// lists and strikethrough) and mapped onto the blocks `MarkdownBuilder` draws. Its own file, since
// the package's `Text`, `Link`, `Table` and `CodeBlock` would hide SwiftUI's and the app's.

extension MarkdownView {
    /// Pure, so a page of history can be parsed off the main actor (`MarkdownCache.prewarm`).
    /// `lineBreaks`: every newline in a paragraph is a line break, as a prompt is shown: the
    /// person's own Shift-Return, as GitHub's comments and Claude's apps keep it, not a space.
    nonisolated static func parse(_ text: String, lineBreaks: Bool = false) -> [Block] {
        parseTopLevel(text, lineBreaks: lineBreaks).flatMap(\.blocks)
    }

    /// The blocks of each of the document's top-level elements, and the line (from 1) it starts on.
    /// Every element but the last is finished whatever follows, so a streaming message settles there.
    nonisolated static func parseTopLevel(_ text: String, lineBreaks: Bool) -> [(line: Int?, blocks: [Block])] {
        // Straight quotes stay straight, as they were written.
        let document = Document(parsing: text, options: .disableSmartOpts)
        return document.children.map { node in
            var reader = BlockReader(lineBreaks: lineBreaks)
            reader.read(node, depth: 0)
            return (node.range?.lowerBound.line, reader.blocks)
        }
    }
}

/// One top-level element's blocks, in order: a list's items and what each holds, nested items one
/// level in.
private struct BlockReader {
    typealias Block = MarkdownView.Block
    let lineBreaks: Bool
    var blocks: [Block] = []

    /// `depth`: how many list items the element is inside.
    mutating func read(_ node: any Markup, depth: Int) {
        switch node {
        case let paragraph as Paragraph:
            blocks.append(.paragraph(inline(paragraph), indent: depth))
        case let heading as Heading:
            blocks.append(.heading(level: heading.level, text: inline(heading)))
        case let code as Markdown.CodeBlock:
            // The info string's first word names the language.
            let language = code.language?.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            blocks.append(.code(lang: language, body: withoutFinalNewline(code.code), indent: depth))
        case let quote as BlockQuote:
            readQuote(quote, depth: depth)
        case let list as UnorderedList:
            for item in list.listItems { readItem(item, marker: "•", depth: depth) }
        case let list as OrderedList:
            // Its own numbers, from where it starts.
            for (i, item) in list.listItems.enumerated() { readItem(item, marker: "\(Int(list.startIndex) + i).", depth: depth) }
        case is ThematicBreak:
            blocks.append(.rule)
        case let table as Markdown.Table:
            let rows = [Array(table.head.cells)] + table.body.rows.map { Array($0.cells) }
            blocks.append(.table(rows.map { $0.map { inline($0) } }, alignments: table.columnAlignments.map {
                switch $0 {
                case .left: .left
                case .center: .center
                case .right: .right
                case nil: .natural
                }
            }))
        case let html as HTMLBlock:
            // Shown as it was written.
            blocks.append(.paragraph(AttributedString(withoutFinalNewline(html.rawHTML)), indent: depth))
        default:
            for child in node.children { read(child, depth: depth) }
        }
    }

    /// A quote's paragraphs, each with the quote's bar; what else it holds is drawn as it would be
    /// outside it.
    private mutating func readQuote(_ quote: BlockQuote, depth: Int) {
        for child in quote.children {
            switch child {
            case let paragraph as Paragraph: blocks.append(.quote(inline(paragraph), indent: depth))
            case let heading as Heading: blocks.append(.quote(inline(heading), indent: depth))
            case let nested as BlockQuote: readQuote(nested, depth: depth)
            default: read(child, depth: depth)
            }
        }
    }

    /// An item's first paragraph is its text, beside the marker; anything after it (paragraphs,
    /// code, a nested list) is one level in.
    private mutating func readItem(_ item: ListItem, marker: String, depth: Int) {
        var children = Array(item.children)[...]
        let text = (children.first as? Paragraph).map { inline($0) } ?? AttributedString()
        if children.first is Paragraph { children = children.dropFirst() }
        blocks.append(.bullet(indent: depth, marker: marker, task: item.checkbox.map { $0 == .checked }, text: text))
        for child in children { read(child, depth: depth + 1) }
    }

    private func inline(_ container: any Markup) -> AttributedString {
        var builder = InlineBuilder(lineBreaks: lineBreaks)
        for child in container.children { builder.add(child, InlineBuilder.Style()) }
        return builder.finish()
    }

    private func withoutFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

/// Inline Markdown as an attributed string with Foundation's presentation intents and links, which
/// `MarkdownBuilder` gives fonts and colors; with GitHub's autolinks, which swift-markdown leaves
/// to its client.
private struct InlineBuilder {
    struct Style: Equatable {
        var intent: InlinePresentationIntent = []
        var link: URL?

        func adding(_ intent: InlinePresentationIntent) -> Style {
            var style = self
            style.intent.insert(intent)
            return style
        }
    }

    let lineBreaks: Bool
    private var out = AttributedString()
    /// Text not appended yet, all in one style: neighbouring text nodes join, so an address split
    /// by an escape or an entity is still found whole.
    private var pending = ""
    private var pendingStyle = Style()

    init(lineBreaks: Bool) { self.lineBreaks = lineBreaks }

    mutating func add(_ node: any Markup, _ style: Style) {
        switch node {
        case let text as Markdown.Text: append(text.string, style)
        case is SoftBreak: append(lineBreaks ? "\n" : " ", style)
        case is LineBreak: append("\n", style)
        case let code as InlineCode: append(code.code, style.adding(.code))
        case let html as InlineHTML: append(html.rawHTML, style.adding(.inlineHTML))
        case is Emphasis: addChildren(of: node, style.adding(.emphasized))
        case is Strong: addChildren(of: node, style.adding(.stronglyEmphasized))
        case is Strikethrough: addChildren(of: node, style.adding(.strikethrough))
        case let link as Markdown.Link:
            var linked = style
            if let url = link.destination.flatMap(URL.init(string:)) { linked.link = url }
            addChildren(of: node, linked)
        case let leaf as any PlainTextConvertibleMarkup where node.childCount == 0:
            append(leaf.plainText, style)
        default:
            // An image's description, and anything else holding inline text.
            addChildren(of: node, style)
        }
    }

    private mutating func addChildren(of node: any Markup, _ style: Style) {
        for child in node.children { add(child, style) }
    }

    private mutating func append(_ text: String, _ style: Style) {
        if style != pendingStyle {
            flush()
            pendingStyle = style
        }
        pending += text
    }

    mutating func finish() -> AttributedString {
        flush()
        return out
    }

    private mutating func flush() {
        guard !pending.isEmpty else { return }
        defer { pending = "" }
        var attributes = AttributeContainer()
        if !pendingStyle.intent.isEmpty { attributes.inlinePresentationIntent = pendingStyle.intent }
        if let link = pendingStyle.link { attributes.link = link }
        let linkable = pendingStyle.link == nil && pendingStyle.intent.isDisjoint(with: [.code, .inlineHTML])
        var start = pending.startIndex
        for (range, url) in linkable ? Autolinks.find(in: pending) : [] {
            out.append(AttributedString(pending[start..<range.lowerBound], attributes: attributes))
            var linked = attributes
            linked.link = url
            out.append(AttributedString(pending[range], attributes: linked))
            start = range.upperBound
        }
        out.append(AttributedString(pending[start...], attributes: attributes))
    }
}

/// GitHub's autolinks: a web address starting with `http://`, `https://`, `ftp://` or `www.`, and an
/// email address, without the punctuation after it. Found by the system's link detector (which
/// also finds bare domains, `README.md` among them, so those are left out), and ended as GitHub ends them.
enum Autolinks {
    /// Made once, and shared by parses off the main actor.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in text: String) -> [(Range<String.Index>, URL)] {
        // Most text holds no address at all, and the detector costs far more than this look.
        guard text.utf8.contains(UInt8(ascii: "@")) || text.contains("://") || text.contains("www."),
              let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let found = text[range]
            let lowered = found.lowercased()
            let email = match.url?.scheme == "mailto"
            guard email || ["http://", "https://", "ftp://"].contains(where: lowered.hasPrefix) || found.hasPrefix("www.") else {
                return nil
            }
            let linked = trimmed(found)
            let address = email && !lowered.hasPrefix("mailto:") ? "mailto:" + linked
                : found.hasPrefix("www.") ? "http://" + linked : String(linked)
            guard !linked.isEmpty, let url = URL(string: address) else { return nil }
            return (linked.startIndex..<linked.endIndex, url)
        }
    }

    /// Where GitHub ends an autolink: before a `<`, and not on trailing punctuation or a `)` it
    /// doesn't open.
    static func trimmed(_ found: Substring) -> Substring {
        var link = found.prefix { $0 != "<" }
        var unmatched = link.count(where: { $0 == ")" }) - link.count(where: { $0 == "(" })
        while let last = link.last {
            if last == ")", unmatched > 0 {
                unmatched -= 1
            } else if !"?!.,:;*_~'\"".contains(last) {
                break
            }
            link = link.dropLast()
        }
        return link
    }
}
