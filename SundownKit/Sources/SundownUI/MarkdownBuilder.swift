import AppKit
import Markdown

// A message's Markdown as the text `MarkdownView` draws, built straight from swift-markdown's tree
// (cmark-gfm: CommonMark, with GitHub's tables, task lists and strikethrough). Nonisolated, so a
// page of history is built off the main actor (`MarkdownView.prewarm`). Its own file, since the
// package's `Text`, `Link`, `Table` and `CodeBlock` would hide SwiftUI's and the app's.

enum MarkdownBuilder {
    /// A whole message's text.
    static func build(_ markdown: String, theme: MarkdownTheme) -> NSAttributedString {
        let text = NSMutableAttributedString()
        var stream = MarkdownStream()
        _ = stream.update(text, to: markdown, theme: theme, streaming: false)
        return text
    }

    /// The text without its Markdown, as Copy puts it on the pasteboard (`plain`).
    static func plainText(_ markdown: String) -> String {
        let text = build(markdown, theme: .standard)
        return plain(text, in: NSRange(location: 0, length: text.length))
    }

    /// Plain text: list markers as "• ", a blank line between blocks, table cells tab-separated,
    /// rules as nothing.
    static func plain(_ text: NSAttributedString, in range: NSRange) -> String {
        var out = ""
        text.enumerateAttribute(.markdownCopyAs, in: range) { value, run, _ in
            if let replacement = value as? String {
                // A marker's characters are replaced once, not once per character.
                var effective = NSRange()
                _ = text.attribute(.markdownCopyAs, at: run.location, longestEffectiveRange: &effective,
                                   in: NSRange(location: 0, length: text.length))
                if replacement == "\t" || replacement == "\n" {
                    // Once per character: adjacent empty cells are one run.
                    out += String(repeating: replacement, count: run.length)
                } else if run.location == effective.location || run.location == range.location {
                    out += replacement
                }
            } else {
                out += (text.string as NSString).substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }

    /// One top-level element's text, `after` the message's text before it: then it starts with
    /// the paragraph break ending that text.
    static func append(_ element: any Markup, to out: NSMutableAttributedString, after: Bool, theme: MarkdownTheme) {
        var writer = Writer(out: out, theme: theme, started: after)
        writer.block(element, Writer.Context(lead: 6 * theme.scale))
    }

    static func color(_ kind: SyntaxHighlight.Kind) -> NSColor {
        switch kind {
        case .comment: .secondaryLabelColor
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemPink
        case .type: .systemTeal
        }
    }
}

/// A message's text kept up to date as its Markdown arrives. New text only ever arrives at the end,
/// and every top-level element but the last is finished whatever follows it (a list's next item, a
/// fence's close or a paragraph's next line all belong to the last), so the text before the last
/// one's first line is settled: neither parsed nor built again. Per delta the work is the size of
/// that last element, not of the message.
struct MarkdownStream {
    private(set) var source = ""
    /// The settled prefix's UTF-8 length in `source`, and its UTF-16 length in the built text.
    private(set) var settledLength = 0
    private var settledEnd = 0
    /// Whether the last update left out a last line that could still make the paragraph above it
    /// a heading (`undecidedLine`).
    private var heldBack = false

    /// Text set from elsewhere (a cache): nothing of it is settled.
    init(source: String = "") { self.source = source }

    /// Brings `text`, built from `source`, up to `markdown`: where it changed and what was there
    /// from that point, or nil when nothing did.
    mutating func update(_ text: NSMutableAttributedString, to markdown: String, theme: MarkdownTheme,
                         streaming: Bool) -> (start: Int, replaced: String)? {
        if markdown.utf8.count == source.utf8.count, markdown == source, !(heldBack && !streaming) { return nil }
        let appended = markdown.utf8.count >= settledLength && settledEnd <= text.length
            && markdown.utf8.prefix(settledLength).elementsEqual(source.utf8.prefix(settledLength))
        if !appended { (settledLength, settledEnd) = (0, 0) }
        source = markdown
        var tail = String(decoding: markdown.utf8.dropFirst(settledLength), as: UTF8.self)
        heldBack = false
        if streaming, let line = Self.undecidedLine(tail) {
            tail = String(tail[..<line])
            heldBack = true
        }
        let elements = Array(Document(parsing: tail, options: .disableSmartOpts).children)
        let built = NSMutableAttributedString()
        var lastStart = 0
        for element in elements {
            lastStart = built.length
            MarkdownBuilder.append(element, to: built, after: settledEnd + built.length > 0, theme: theme)
        }
        // One edit, so the text is laid out again once.
        let range = NSRange(location: settledEnd, length: text.length - settledEnd)
        let replaced = (text.string as NSString).substring(with: range)
        text.replaceCharacters(in: range, with: built)
        // Not while the last element starts on an unfinished line: as it grows it can join the one
        // before ("|" is a paragraph; "| Rows |" a table's row).
        if elements.count > 1, let line = elements.last?.range?.lowerBound.line, let offset = Self.offset(ofLine: line, in: tail),
           tail.utf8.dropFirst(offset).contains(UInt8(ascii: "\n")) {
            settledEnd += lastStart
            settledLength += offset
        }
        return (range.location, replaced)
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
        let utf8 = text.utf8
        var current = 1
        var offset = 0
        var i = utf8.startIndex
        while current < line, i != utf8.endIndex {
            let byte = utf8[i]
            utf8.formIndex(after: &i)
            offset += 1
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") && (i == utf8.endIndex || utf8[i] != UInt8(ascii: "\n")) {
                current += 1
            }
        }
        return current == line ? offset : nil
    }
}

/// Writes one top-level element's blocks.
private struct Writer {
    let out: NSMutableAttributedString
    let theme: MarkdownTheme
    /// Whether a block was written before: the next starts with a paragraph break.
    private var started: Bool
    /// Whether the last block written was a list item's line: the next item sits closer.
    private var previousItem = false

    init(out: NSMutableAttributedString, theme: MarkdownTheme, started: Bool) {
        self.out = out
        self.theme = theme
        self.started = started
    }

    /// Where a block sits: `inset` where its text starts (inside a list item, the item's text),
    /// `lead` where a list in it puts its markers, `depth` how many lists it's in.
    struct Context {
        var inset: CGFloat = 0
        var lead: CGFloat
        var depth = 0
        var quoted = false
    }

    mutating func block(_ node: any Markup, _ c: Context) {
        switch node {
        case let paragraph as Paragraph:
            self.paragraph(inline(paragraph, font: theme.body, color: c.quoted ? theme.secondary : theme.text), c)
        case let html as HTMLBlock:
            // Shown as it was written.
            let raw = html.rawHTML.hasSuffix("\n") ? String(html.rawHTML.dropLast()) : html.rawHTML
            self.paragraph(NSAttributedString(string: raw, attributes: [.font: theme.body, .foregroundColor: theme.text]), c)
        case let heading as Heading:
            let before = begin(heading: true)
            let start = out.length
            out.append(inline(heading, font: theme.heading(heading.level), color: theme.text))
            setParagraph(from: start, style(before, indent: c.inset))
            out.addAttribute(.markdownHeading, value: heading.level, range: NSRange(location: start, length: out.length - start))
        case let quote as BlockQuote:
            var inner = c
            inner.inset += theme.quoteIndent
            inner.lead += theme.quoteIndent
            inner.quoted = true
            for child in quote.children { block(child, inner) }
        case let list as UnorderedList:
            let items = Array(list.listItems)
            self.list(items, markers: items.map { _ in "•" }, c)
        case let list as OrderedList:
            // Its own numbers, from where it starts.
            let items = Array(list.listItems)
            self.list(items, markers: items.indices.map { "\(Int(list.startIndex) + $0)." }, c)
        case let code as Markdown.CodeBlock:
            // The info string's first word names the language.
            let language = code.language?.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            self.code(body, language: language, c)
        case is ThematicBreak:
            // A paragraph the line is drawn across; copied as nothing.
            let before = begin()
            let start = out.length
            out.append(NSAttributedString(string: " ", attributes: [
                .font: theme.body, .markdownCopyAs: "", .markdownDecoration: MarkdownDecoration(.rule),
            ]))
            setParagraph(from: start, style(before, indent: 0))
        case let table as Markdown.Table:
            self.table(table)
        default:
            for child in node.children { block(child, c) }
        }
    }

    /// Starts a block: the paragraph break ending the block before, if any, in a tiny font, so it
    /// doesn't make that block's last line taller, and copied as a blank line, or a line between
    /// items of a list. Returns the room above it: list items sit closer, headings have more.
    private mutating func begin(item: Bool = false, heading: Bool = false) -> CGFloat {
        defer { (started, previousItem) = (true, item) }
        guard started else { return 0 }
        let tight = item && previousItem
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .markdownCopyAs: tight ? "\n" : "\n\n",
        ]))
        return (tight ? 6 : heading ? 18 : 12) * theme.scale
    }

    private func style(_ before: CGFloat, indent: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = theme.lineSpacing
        p.paragraphSpacingBefore = before
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        return p
    }

    private func setParagraph(from start: Int, _ style: NSParagraphStyle) {
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        // A line break inside the block (a prompt's) starts a paragraph for TextKit, which would
        // put the block's spacing above each line: only its first line has it.
        let lineBreak = (out.string as NSString).range(of: "\n", range: NSRange(location: start, length: out.length - start))
        guard lineBreak.location != NSNotFound, style.paragraphSpacingBefore != 0,
              let rest = style.mutableCopy() as? NSMutableParagraphStyle else { return }
        rest.paragraphSpacingBefore = 0
        let from = lineBreak.location + 1
        out.addAttribute(.paragraphStyle, value: rest, range: NSRange(location: from, length: out.length - from))
    }

    private mutating func paragraph(_ text: NSAttributedString, _ c: Context) {
        let before = begin()
        let start = out.length
        out.append(text)
        setParagraph(from: start, style(before, indent: c.inset))
        if c.quoted {
            out.addAttribute(.markdownDecoration, value: MarkdownDecoration(.quote),
                             range: NSRange(location: start, length: out.length - start))
        }
    }

    /// Each item's marker right-aligned to the list's widest ("10." in a list that reaches ten), so
    /// their text starts at one edge; its first paragraph beside the marker, and anything after it
    /// (paragraphs, code, a nested list) lined up with that text.
    private mutating func list(_ items: [ListItem], markers: [String], _ c: Context) {
        let markerFont = theme.body.withMonospacedDigits
        let widest = NSAttributedString(string: markers.last ?? "•", attributes: [.font: markerFont]).size().width
        let markerEnd = c.lead + max(widest, 12 * theme.scale)
        let textStart = markerEnd + 8 * theme.scale
        let inner = Context(inset: textStart, lead: c.lead + 18 * theme.scale, depth: c.depth + 1, quoted: c.quoted)
        for (item, marker) in zip(items, markers) {
            var children = Array(item.children)[...]
            let first = children.first as? Paragraph
            if first != nil { children.removeFirst() }

            let before = begin(item: true)
            let start = out.length
            let markerAttributes: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: theme.secondary]
            out.append(NSAttributedString(string: "\t", attributes: markerAttributes))
            if let task = item.checkbox {
                // A task list's box, checked or not, in place of its marker.
                let done = task == .checked
                let attachment = NSTextAttachment()
                attachment.image = NSImage(systemSymbolName: done ? "checkmark.square.fill" : "square",
                                           accessibilityDescription: done ? "Done" : "Not done")?
                    .withSymbolConfiguration(.init(pointSize: theme.body.pointSize, weight: .regular))
                let box = NSMutableAttributedString(attachment: attachment)
                box.addAttributes([.foregroundColor: done ? NSColor.controlAccentColor : theme.secondary,
                                   .baselineOffset: -1 * theme.scale], range: NSRange(location: 0, length: box.length))
                out.append(box)
            } else {
                out.append(NSAttributedString(string: marker, attributes: markerAttributes))
            }
            out.append(NSAttributedString(string: "\t", attributes: markerAttributes))
            let copied = item.checkbox.map { $0 == .checked ? "[x] " : "[ ] " } ?? (marker == "•" ? "• " : marker + " ")
            out.addAttribute(.markdownCopyAs, value: String(repeating: "  ", count: c.depth) + copied,
                             range: NSRange(location: start, length: out.length - start))
            if let first { out.append(inline(first, font: theme.body, color: theme.text)) }
            let p = style(before, indent: textStart)
            p.firstLineHeadIndent = c.lead
            p.tabStops = [NSTextTab(textAlignment: .right, location: markerEnd), NSTextTab(textAlignment: .left, location: textStart)]
            setParagraph(from: start, p)

            for child in children { block(child, inner) }
        }
    }

    private mutating func code(_ body: String, language: String, _ c: Context) {
        let before = begin()
        let start = out.length
        let code = body.isEmpty ? " " : body
        let colored = NSMutableAttributedString(string: code, attributes: [.font: theme.code, .foregroundColor: theme.text])
        // Code in Xcode's colors, from `SyntaxHighlight`'s scan; plain for a language it doesn't know.
        if theme.style == .reply, code.utf8.count <= SyntaxHighlight.limit, let grammar = SyntaxHighlight.grammar(for: language) {
            let utf8 = code.utf8
            for run in SyntaxHighlight.scan(Array(utf8), grammar) {
                let lower = utf8.index(utf8.startIndex, offsetBy: run.start)
                let upper = utf8.index(utf8.startIndex, offsetBy: run.end)
                colored.addAttribute(.foregroundColor, value: MarkdownBuilder.color(run.kind), range: NSRange(lower..<upper, in: code))
            }
        }
        out.append(colored)
        let range = NSRange(location: start, length: out.length - start)
        // Inside a list item, the box starts where the item's text does.
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2 * theme.scale
        p.headIndent = c.inset + theme.codeInset
        p.firstLineHeadIndent = c.inset + theme.codeInset
        p.tailIndent = -theme.codeInset
        out.addAttribute(.paragraphStyle, value: p, range: range)
        // The first line leaves room for the box's header, the last for its foot.
        let first = (out.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        let top = p.mutableCopy() as! NSMutableParagraphStyle
        top.paragraphSpacingBefore = before + theme.codeHeader
        out.addAttribute(.paragraphStyle, value: top, range: first)
        let last = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        let bottom = (last == first ? top : p).mutableCopy() as! NSMutableParagraphStyle
        bottom.paragraphSpacing = theme.codeBottom
        out.addAttribute(.paragraphStyle, value: bottom, range: last)
        out.addAttribute(.markdownDecoration, value: MarkdownDecoration(.code(language: language, source: body)), range: range)
    }

    private mutating func table(_ table: Markdown.Table) {
        let rows = [Array(table.head.cells)] + table.body.rows.map { Array($0.cells) }
        let columns = rows[0].count
        guard columns > 0 else { return }
        let before = begin()
        let start = out.length
        let grid = NSTextTable()
        grid.numberOfColumns = columns
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false
        grid.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
        let alignments = table.columnAlignments
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(5 * theme.scale, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(5 * theme.scale, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(10 * theme.scale, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10 * theme.scale, type: .absoluteValueType, for: .padding, edge: .maxX)
                if r == 0 {
                    cell.setBorderColor(theme.rule, for: .maxY)
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                }
                let cellStart = out.length
                if c < row.count { out.append(inline(row[c], font: r == 0 ? theme.body.bold : theme.body, color: theme.text)) }
                // A tab between cells and a line between rows when copied, as a spreadsheet takes them.
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: theme.body, .markdownCopyAs: c == columns - 1 ? "\n" : "\t",
                ]))
                let p = NSMutableParagraphStyle()
                p.textBlocks = [cell]
                p.lineSpacing = theme.lineSpacing
                p.alignment = switch c < alignments.count ? alignments[c] : nil {
                case .left: .left
                case .center: .center
                case .right: .right
                case nil: .natural
                }
                out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: cellStart, length: out.length - cellStart))
            }
        }
        // The table's last newline ends the last cell's paragraph; the next block's break does that.
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        out.addAttribute(.markdownDecoration, value: MarkdownDecoration(.table), range: NSRange(location: start, length: out.length - start))
    }

    // MARK: Inline

    /// Inline Markdown with fonts and colors: emphasis, strong, code, strikethrough and links, and
    /// GitHub's autolinks, which swift-markdown leaves to its client.
    private func inline(_ container: any Markup, font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        struct Style { var bold = false, italic = false, strike = false, link: URL? }
        func add(_ node: any Markup, _ style: Style) {
            func text(_ string: String, code: Bool = false) {
                var runFont = font
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if code {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: font.isBold ? .semibold : .regular)
                    attributes[.markdownInlineCode] = true
                }
                if style.bold { runFont = runFont.bold }
                if style.italic { runFont = runFont.italic }
                attributes[.font] = runFont
                if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = style.link { attributes.merge(linkAttributes(link)) { $1 } }
                out.append(NSAttributedString(string: string, attributes: attributes))
            }
            var inner = style
            switch node {
            case let t as Markdown.Text: return text(t.string)
            case is SoftBreak: return text(theme.style == .prompt ? "\n" : " ")
            case is LineBreak: return text("\n")
            case let code as InlineCode: return text(code.code, code: true)
            case let html as InlineHTML: return text(html.rawHTML)
            case is Emphasis: inner.italic = true
            case is Strong: inner.bold = true
            case is Strikethrough: inner.strike = true
            case let link as Markdown.Link: inner.link = link.destination.flatMap(URL.init(string:)) ?? style.link
            case let leaf as any PlainTextConvertibleMarkup where node.childCount == 0: return text(leaf.plainText)
            default: break // an image's description, and anything else holding inline text
            }
            for child in node.children { add(child, inner) }
        }
        for child in container.children { add(child, Style()) }
        autolink(out)
        // Room for the fill on either side of inline code: kerning after the character before it
        // and after its last character, so its neighbors don't touch the fill.
        let pad = 4 * theme.scale
        out.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: out.length)) { value, run, _ in
            guard value != nil, run.length > 0 else { return }
            if run.location > 0 { out.addAttribute(.kern, value: pad, range: NSRange(location: run.location - 1, length: 1)) }
            out.addAttribute(.kern, value: pad, range: NSRange(location: run.location + run.length - 1, length: 1))
        }
        return out
    }

    private func linkAttributes(_ url: URL) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .link: url, .toolTip: url.isFileURL ? url.path : url.absoluteString, .foregroundColor: theme.link,
        ]
        if theme.style == .prompt { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// GitHub's autolinks: web addresses starting `http://`, `https://`, `ftp://` or `www.`, and
    /// email addresses, as the system's link detector ends them. Not bare domains, which it also
    /// finds: `README.md` is a file.
    private func autolink(_ text: NSMutableAttributedString) {
        let string = text.string
        guard string.contains("://") || string.contains("www.") || string.contains("@"), let detector = Self.detector else { return }
        for match in detector.matches(in: string, range: NSRange(location: 0, length: text.length)) {
            guard let url = match.url else { continue }
            let found = (string as NSString).substring(with: match.range).lowercased()
            guard url.scheme == "mailto" || ["http://", "https://", "ftp://", "www."].contains(where: found.hasPrefix) else { continue }
            var taken = false
            text.enumerateAttributes(in: match.range) { attributes, _, stop in
                if attributes[.link] != nil || attributes[.markdownInlineCode] != nil { taken = true; stop.pointee = true }
            }
            if !taken { text.addAttributes(linkAttributes(url), range: match.range) }
        }
    }
}

extension NSFont {
    var bold: NSFont { adding(.bold) ?? self }
    /// The system font has no italic face in some weights; a slant reads as one.
    var italic: NSFont {
        adding(.italic) ?? NSFont(descriptor: fontDescriptor.withMatrix(AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)),
                                  size: pointSize) ?? self
    }
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var withMonospacedDigits: NSFont { .monospacedDigitSystemFont(ofSize: pointSize, weight: .regular) }

    private func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let font = NSFont(descriptor: fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)), size: pointSize)
        return font.map { $0.fontDescriptor.symbolicTraits.contains(trait) ? $0 : nil } ?? nil
    }
}
