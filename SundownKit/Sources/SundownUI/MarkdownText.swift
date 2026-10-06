import AppKit
import SwiftUI

/// Whose message a Markdown text is: a reply on the window's background, or a prompt in its blue
/// bubble, whose text is white.
enum MarkdownStyle: Hashable {
    case reply
    case prompt
}

/// A message's Markdown as one read-only, selectable TextKit text view, so a selection runs across
/// paragraphs, headings, lists, quotes, code and tables, links take the pointing hand and show where
/// they go, and wrapped list items hang. AppKit, because SwiftUI has no selection that spans views:
/// one `Text` per block selected a block at a time, and one `Text` for the whole reply ignores
/// paragraph styles, so lists and quotes lost their indents (macOS 27, 2026-10-05).
///
/// It takes the parsed blocks (`MarkdownCache`) and turns only the changed ones into text, so a
/// streamed reply rebuilds its tail, not the whole message, and new text fades in.
struct MarkdownTextView: NSViewRepresentable {
    let blocks: [MarkdownView.Rendered]
    var style: MarkdownStyle = .reply
    /// The reply being streamed into: its new text fades in.
    var streams = false
    /// The whole message, the key for the text built from it once it has settled.
    var source: String

    // Read so a change updates the view; `setText` takes them from the context, as sizing must.
    @Environment(\.textScale) private var textScale
    @Environment(\.openURL) private var openURL
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.findQuery) private var findQuery

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkdownNSTextView {
        let view = MarkdownNSTextView.make()
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: MarkdownNSTextView, context: Context) {
        context.coordinator.openURL = openURL
        setText(of: view, context)
        context.coordinator.highlight(findQuery)
    }

    /// The view's text as this value has it. Also before sizing: SwiftUI can ask a new row its size
    /// before its first update, and an empty text measured a line tall until the next layout.
    private func setText(of view: MarkdownNSTextView, _ context: Context) {
        let theme = MarkdownTheme(style: style, scale: context.environment.textScale,
                                  increasedContrast: context.environment.colorSchemeContrast == .increased)
        view.theme = theme
        context.coordinator.apply(blocks, source: source, theme: theme, streams: streams)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownNSTextView, context: Context) -> CGSize? {
        setText(of: nsView, context)
        guard let width = proposal.width, width.isFinite else {
            // Its ideal size: the text unwrapped.
            let size = nsView.measure(width: 10_000, natural: true)
            return size
        }
        let size = nsView.measure(width: max(width, 1))
        // A prompt's bubble hugs its text; a reply takes the column.
        return CGSize(width: style == .prompt ? min(width, size.width) : width, height: size.height)
    }

    static func dismantleNSView(_ view: MarkdownNSTextView, coordinator: Coordinator) {
        coordinator.stopFading()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: MarkdownNSTextView?
        var openURL: OpenURLAction?
        /// What the storage holds: how each block was built, and where it ends.
        private var records: [(key: BuildKey, end: Int)] = []
        private var theme: MarkdownTheme?
        /// Built blocks, kept while the reply streams, so only its tail is built again.
        private var built: [BuildKey: NSAttributedString] = [:]
        private var fades: [(range: NSRange, start: CFTimeInterval)] = []
        private var displayLink: CADisplayLink?

        /// A block as built: the same parse at the same place in the same list builds the same text.
        struct BuildKey: Hashable {
            let id: Int
            let leading: Bool
            let spacing: CGFloat
            let marker: String?
        }

        /// Whole settled messages already built, so a row scrolled back into view or a chat
        /// reopened sets its text at once. Bounded by size too: a long chat's replies are megabytes.
        private static let settled: NSCache<NSString, NSAttributedString> = {
            let cache = NSCache<NSString, NSAttributedString>()
            cache.countLimit = 300
            cache.totalCostLimit = 8 << 20
            return cache
        }()

        private static func keys(for blocks: [MarkdownView.Rendered]) -> [BuildKey] {
            let markers = MarkdownView.widestMarkers(blocks)
            return blocks.indices.map { i in
                BuildKey(id: blocks[i].id, leading: i > 0,
                         spacing: i == 0 ? 0 : MarkdownBuilder.spacing(after: blocks[i - 1].block, before: blocks[i].block),
                         marker: markers[i])
            }
        }

        func apply(_ blocks: [MarkdownView.Rendered], source: String, theme: MarkdownTheme, streams: Bool) {
            guard let view, let storage = view.textStorage else { return }
            if theme != self.theme {
                self.theme = theme
                records = []
                built = [:]
                storage.setAttributedString(NSAttributedString())
            }
            let keys = Self.keys(for: blocks)
            if keys.count == records.count, zip(keys, records).allSatisfy({ $0 == $1.key }) { return }
            // Find's marks went with the text they were on.
            highlighted = nil

            let cacheKey = "\(theme.cacheKey)|\(NSFont.preferredFont(forTextStyle: .body).pointSize)|\(source)" as NSString
            if records.isEmpty, storage.length == 0, !streams, let cached = Self.settled.object(forKey: cacheKey) {
                storage.setAttributedString(cached)
                records = Self.records(for: keys, in: cached)
                view.textChanged()
                return
            }

            // From the first block built differently: a new parse, or a list whose widest marker
            // grew, which moves every item's text.
            var first = 0
            while first < min(keys.count, records.count), keys[first] == records[first].key { first += 1 }
            let start = first == 0 ? 0 : records[first - 1].end
            let old = storage.length > start
                ? (storage.string as NSString).substring(from: start)
                : ""

            let tail = NSMutableAttributedString()
            var newRecords = Array(records.prefix(first))
            var keep: [BuildKey: NSAttributedString] = [:]
            for i in blocks.indices where i >= first || streams {
                let key = keys[i]
                let piece = built[key] ?? MarkdownBuilder.build(blocks[i], leading: key.leading, spacing: key.spacing,
                                                               widestMarker: key.marker, theme: theme)
                if streams { keep[key] = piece }
                if i >= first {
                    tail.append(piece)
                    newRecords.append((key, start + tail.length))
                }
            }
            built = keep

            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
            storage.endEditing()
            records = newRecords

            if streams {
                // What's new is whatever follows the text both versions share. A fade reaching past
                // that point goes on over what's left of its text; the new text loses whatever
                // fade it took from the text it replaced (left there, a word's end stayed
                // invisible once the reply had settled), and fades in afresh.
                let shared = (old as NSString).commonPrefix(with: tail.string, options: .literal).utf16.count
                let cut = start + shared
                fades = fades.compactMap { fade in
                    let end = min(fade.range.location + fade.range.length, cut)
                    return end > fade.range.location ? (NSRange(location: fade.range.location, length: end - fade.range.location), fade.start) : nil
                }
                let range = NSRange(location: cut, length: tail.length - shared)
                if range.length > 0 {
                    view.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                    fade(range)
                }
            } else {
                stopFading()
                Self.settled.setObject(storage.copy() as! NSAttributedString, forKey: cacheKey, cost: storage.length * 2)
            }
            view.textChanged()
        }

        /// Where each block ends in a text built in one go, found from the separators between blocks.
        private static func records(for keys: [BuildKey], in text: NSAttributedString) -> [(key: BuildKey, end: Int)] {
            var ends: [Int] = []
            text.enumerateAttribute(.markdownBlockEnd, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if value != nil { ends.append(range.location + range.length) }
            }
            guard ends.count == keys.count else { return [] }
            return Array(zip(keys, ends))
        }

        // MARK: Find

        private var highlighted: String?
        private var highlightedLength = 0

        /// Find in Chat's matches in this text, marked as the system marks found text. Temporary
        /// attributes, so the text isn't laid out again.
        func highlight(_ query: String?) {
            guard let view, let layout = view.layoutManager, let storage = view.textStorage else { return }
            let query = query?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            guard query != highlighted || storage.length != highlightedLength else { return }
            highlighted = query
            highlightedLength = storage.length
            let all = NSRange(location: 0, length: storage.length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            guard let query else { return }
            let text = storage.string as NSString
            var range = NSRange(location: 0, length: text.length)
            while range.length > 0 {
                let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard found.location != NSNotFound else { break }
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.55),
                                             forCharacterRange: found)
                range = NSRange(location: found.upperBound, length: text.length - found.upperBound)
            }
        }

        // MARK: Fading in

        private func fade(_ range: NSRange) {
            fades.append((range, CACurrentMediaTime()))
            redrawFades()
            if displayLink == nil, let view {
                let link = view.displayLink(target: self, selector: #selector(step))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        @objc private func step() { redrawFades() }

        private func redrawFades() {
            guard let view, let layout = view.layoutManager, let storage = view.textStorage else { return }
            let now = CACurrentMediaTime()
            let length = storage.length
            for (range, _) in fades {
                let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
                if clipped.length > 0 { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clipped) }
            }
            fades.removeAll { now - $0.start >= MarkdownTheme.fadeDuration }
            for (range, start) in fades {
                let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
                guard clipped.length > 0 else { continue }
                // Eased out, so a piece is readable almost at once and settles gently.
                let progress = max(0, (now - start) / MarkdownTheme.fadeDuration)
                let alpha = 1 - pow(1 - progress, 2)
                storage.enumerateAttribute(.foregroundColor, in: clipped) { value, run, _ in
                    let color = (value as? NSColor) ?? .labelColor
                    layout.addTemporaryAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * alpha),
                                                 forCharacterRange: run)
                }
            }
            if fades.isEmpty { stopFading() }
        }

        func stopFading() {
            displayLink?.invalidate()
            displayLink = nil
            if let view, let layout = view.layoutManager, let storage = view.textStorage, !fades.isEmpty {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            }
            fades = []
        }

        // MARK: Links

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if let openURL { openURL(url) } else { NSWorkspace.shared.open(url) }
            return true
        }
    }
}

// MARK: - Theme

/// Fonts, colors and measures for one style at one text size. Colors are the system's dynamic
/// ones, so the text follows the appearance without being built again.
struct MarkdownTheme: Equatable {
    let style: MarkdownStyle
    let scale: CGFloat
    let increasedContrast: Bool

    static let fadeDuration: CFTimeInterval = 0.3

    var cacheKey: String { "\(style)|\(scale)|\(increasedContrast)" }

    func size(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize * scale
    }

    var body: NSFont { .systemFont(ofSize: size(.body)) }
    var code: NSFont { .monospacedSystemFont(ofSize: size(.callout), weight: .regular) }
    var caption: NSFont { .systemFont(ofSize: size(.caption1), weight: .medium) }
    func heading(_ level: Int) -> NSFont {
        let style: NSFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
        return .systemFont(ofSize: size(style), weight: .bold)
    }

    var text: NSColor { style == .prompt ? .white : .labelColor }
    var secondary: NSColor { style == .prompt ? .white.withAlphaComponent(0.75) : .secondaryLabelColor }
    var link: NSColor { style == .prompt ? .white : .linkColor }
    var inlineCodeFill: NSColor {
        style == .prompt ? .white.withAlphaComponent(0.2) : .labelColor.withAlphaComponent(0.08)
    }
    var codeFill: NSColor { style == .prompt ? .black.withAlphaComponent(0.18) : .tertiarySystemFill }
    var codeStroke: NSColor {
        style == .prompt ? .white.withAlphaComponent(0.2) : .labelColor.withAlphaComponent(increasedContrast ? 0.4 : 0.12)
    }
    var tableFill: NSColor { style == .prompt ? .black.withAlphaComponent(0.12) : .quinarySystemFill }
    var quoteBar: NSColor { style == .prompt ? .white.withAlphaComponent(0.5) : .tertiaryLabelColor }
    var rule: NSColor { style == .prompt ? .white.withAlphaComponent(0.4) : .separatorColor }

    /// Code's inset inside its box, and the box's header, where its language and Copy go.
    var codeInset: CGFloat { 12 * scale }
    var codeHeader: CGFloat { 26 * scale }
    var codeBottom: CGFloat { 10 * scale }
    var lineSpacing: CGFloat { 3 * scale }
    var quoteIndent: CGFloat { 14 * scale }
}

// MARK: - Building text

extension EnvironmentValues {
    /// Find in Chat's query, set on the rows that match it, for their text to mark.
    @Entry var findQuery: String? = nil
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension NSAttributedString.Key {
    /// A block drawn with a background: a code block, quote, table or rule (`MarkdownDecoration`).
    static let markdownDecoration = NSAttributedString.Key("SundownMarkdownDecoration")
    /// Inline code, drawn on a rounded fill.
    static let markdownInlineCode = NSAttributedString.Key("SundownMarkdownInlineCode")
    /// What Copy puts on the pasteboard in place of these characters (a list marker's tabs).
    static let markdownCopyAs = NSAttributedString.Key("SundownMarkdownCopyAs")
    /// A heading's level, for VoiceOver's headings rotor.
    static let markdownHeading = NSAttributedString.Key("SundownMarkdownHeading")
    /// The last character of a block, so a text built once can be split into its blocks again.
    static let markdownBlockEnd = NSAttributedString.Key("SundownMarkdownBlockEnd")
}

/// One drawn block: the same object across its characters, so its whole range can be found.
final class MarkdownDecoration: NSObject {
    enum Kind: Equatable { case code(language: String, source: String), quote, table, rule }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

@MainActor
enum MarkdownBuilder {
    /// List items sit closer together than paragraphs; headings have more room above.
    static func spacing(after previous: MarkdownView.Block, before block: MarkdownView.Block) -> CGFloat {
        if case .bullet = previous, case .bullet = block { return 6 }
        if case .heading = block { return 18 }
        return 12
    }

    /// One block's text, starting with the newline that ends the block before it.
    static func build(_ rendered: MarkdownView.Rendered, leading: Bool, spacing: CGFloat, widestMarker: String?,
                      theme: MarkdownTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if leading {
            // The paragraph break belongs to the block before; a tiny font keeps it from making
            // that block's last line taller.
            // Copied as a blank line between blocks, as Markdown writes them, except between items
            // of one list.
            let tight: Bool = if case .bullet = rendered.block, spacing == 6 { true } else { false }
            out.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 1), .markdownCopyAs: tight ? "\n" : "\n\n",
            ]))
        }
        let spacingBefore = spacing * theme.scale
        let start = out.length
        switch rendered.block {
        case .paragraph:
            out.append(inline(rendered.inline.first, font: theme.body, color: theme.text, theme: theme))
            setParagraph(out, from: start, style(theme, before: spacingBefore))
        case .heading(let level, _):
            out.append(inline(rendered.inline.first, font: theme.heading(level), color: theme.text, theme: theme))
            setParagraph(out, from: start, style(theme, before: spacingBefore))
            out.addAttribute(.markdownHeading, value: level, range: NSRange(location: start, length: out.length - start))
        case .bullet(let indent, let marker, let text):
            appendListItem(out, indent: indent, marker: marker, text: text, inline: rendered.inline.first,
                           widest: widestMarker ?? marker, before: spacingBefore, theme: theme)
        case .quote:
            out.append(inline(rendered.inline.first, font: theme.body, color: theme.secondary, theme: theme))
            let p = style(theme, before: spacingBefore)
            p.headIndent = theme.quoteIndent
            p.firstLineHeadIndent = theme.quoteIndent
            setParagraph(out, from: start, p)
            out.addAttribute(.markdownDecoration, value: MarkdownDecoration(.quote),
                             range: NSRange(location: start, length: out.length - start))
        case .code(let lang, let body):
            appendCode(out, language: lang, body: body, before: spacingBefore, theme: theme)
        case .rule:
            // A paragraph the line is drawn across; copied as nothing.
            out.append(NSAttributedString(string: " ", attributes: [
                .font: theme.body, .markdownCopyAs: "",
                .markdownDecoration: MarkdownDecoration(.rule),
            ]))
            setParagraph(out, from: start, style(theme, before: spacingBefore))
        case .table(let rows):
            appendTable(out, rows: rows, inline: rendered.inline, before: spacingBefore, theme: theme)
        }
        if out.length > start {
            out.addAttribute(.markdownBlockEnd, value: true, range: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func style(_ theme: MarkdownTheme, before: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = theme.lineSpacing
        p.paragraphSpacingBefore = before
        return p
    }

    private static func setParagraph(_ out: NSMutableAttributedString, from start: Int, _ style: NSParagraphStyle) {
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

    private static func appendListItem(_ out: NSMutableAttributedString, indent: Int, marker: String, text: String,
                                       inline parsed: AttributedString?, widest: String, before: CGFloat,
                                       theme: MarkdownTheme) {
        let start = out.length
        var parsed = parsed
        // A task list's box, checked or not, in place of its bullet.
        var task: Bool?
        if marker == "•", let first = parsed.map({ String($0.characters.prefix(4)) }) {
            if first == "[ ] " { task = false } else if first.lowercased() == "[x] " { task = true }
            if task != nil, var p = parsed {
                p.removeSubrange(p.startIndex..<p.characters.index(p.startIndex, offsetBy: 4))
                parsed = p
            }
        }
        let markerFont = theme.body.withMonospacedDigits
        let lead = (6 + CGFloat(indent) * 18) * theme.scale
        let widestWidth = NSAttributedString(string: widest, attributes: [.font: markerFont]).size().width
        let markerEnd = lead + max(widestWidth, 12 * theme.scale)
        let textStart = markerEnd + 8 * theme.scale

        let markerAttributes: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: theme.secondary]
        out.append(NSAttributedString(string: "\t", attributes: markerAttributes))
        if let task {
            let symbol = NSImage(systemSymbolName: task ? "checkmark.square.fill" : "square",
                                 accessibilityDescription: task ? "Done" : "Not done")
            let attachment = NSTextAttachment()
            attachment.image = symbol?.withSymbolConfiguration(.init(pointSize: theme.body.pointSize, weight: .regular))
            let box = NSMutableAttributedString(attachment: attachment)
            box.addAttributes([.foregroundColor: task ? NSColor.controlAccentColor : theme.secondary,
                               .baselineOffset: -1 * theme.scale],
                              range: NSRange(location: 0, length: box.length))
            out.append(box)
        } else {
            out.append(NSAttributedString(string: marker, attributes: markerAttributes))
        }
        out.append(NSAttributedString(string: "\t", attributes: markerAttributes))
        let copyMarker = task.map { $0 ? "[x] " : "[ ] " } ?? (marker == "•" ? "• " : marker + " ")
        out.addAttribute(.markdownCopyAs, value: String(repeating: "  ", count: indent) + copyMarker,
                         range: NSRange(location: start, length: out.length - start))
        out.append(inline(parsed, fallback: text, font: theme.body, color: theme.text, theme: theme))

        let p = style(theme, before: before)
        p.firstLineHeadIndent = lead
        p.headIndent = textStart
        p.tabStops = [NSTextTab(textAlignment: .right, location: markerEnd), NSTextTab(textAlignment: .left, location: textStart)]
        setParagraph(out, from: start, p)
    }

    private static func appendCode(_ out: NSMutableAttributedString, language: String, body: String, before: CGFloat,
                                   theme: MarkdownTheme) {
        let start = out.length
        let code = body.isEmpty ? " " : body
        let colored = NSMutableAttributedString(string: code, attributes: [.font: theme.code, .foregroundColor: theme.text])
        if theme.style == .reply { highlight(colored, code: code, language: language) }
        out.append(colored)
        let range = NSRange(location: start, length: out.length - start)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2 * theme.scale
        p.headIndent = theme.codeInset
        p.firstLineHeadIndent = theme.codeInset
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

    /// Code in Xcode's colors, from `SyntaxHighlight`'s scan; plain for a language it doesn't know.
    private static func highlight(_ text: NSMutableAttributedString, code: String, language: String) {
        guard code.utf8.count <= SyntaxHighlight.limit, let grammar = SyntaxHighlight.grammar(for: language) else { return }
        let utf8 = code.utf8
        for run in SyntaxHighlight.scan(Array(utf8), grammar) {
            let lower = utf8.index(utf8.startIndex, offsetBy: run.start)
            let upper = utf8.index(utf8.startIndex, offsetBy: run.end)
            text.addAttribute(.foregroundColor, value: color(run.kind), range: NSRange(lower..<upper, in: code))
        }
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

    private static func appendTable(_ out: NSMutableAttributedString, rows: [[String]], inline: [AttributedString],
                                    before: CGFloat, theme: MarkdownTheme) {
        let columns = rows.first?.count ?? 0
        guard columns > 0 else { return }
        let start = out.length
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(5 * theme.scale, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(5 * theme.scale, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(10 * theme.scale, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(10 * theme.scale, type: .absoluteValueType, for: .padding, edge: .maxX)
                if r == 0 {
                    block.setBorderColor(theme.rule, for: .maxY)
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                }
                let index = r * columns + c
                let cellStart = out.length
                let text = index < inline.count ? inline[index] : AttributedString(c < row.count ? row[c] : "")
                out.append(Self.inline(text, font: r == 0 ? theme.body.bold : theme.body, color: theme.text, theme: theme))
                // A tab between cells and a line between rows when copied, as a spreadsheet takes them.
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: theme.body, .markdownCopyAs: c == columns - 1 ? "\n" : "\t",
                ]))
                let p = NSMutableParagraphStyle()
                p.textBlocks = [block]
                p.lineSpacing = theme.lineSpacing
                out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: cellStart, length: out.length - cellStart))
            }
        }
        // The table's last newline is the block's end, ending the last cell's paragraph.
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        out.addAttribute(.markdownDecoration, value: MarkdownDecoration(.table), range: NSRange(location: start, length: out.length - start))
    }

    /// Inline Markdown with fonts and colors: emphasis, strong, code, strikethrough and links.
    static func inline(_ parsed: AttributedString?, fallback: String = "", font: NSFont, color: NSColor,
                       theme: MarkdownTheme) -> NSAttributedString {
        guard let parsed else { return NSAttributedString(string: fallback, attributes: [.font: font, .foregroundColor: color]) }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let string = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: font.isBold ? .semibold : .regular)
                    attributes[.markdownInlineCode] = true
                }
                if intent.contains(.stronglyEmphasized) { runFont = runFont.bold }
                if intent.contains(.emphasized) { runFont = runFont.italic }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let url = run.link {
                attributes[.link] = url
                attributes[.toolTip] = url.isFileURL ? url.path : url.absoluteString
                attributes[.foregroundColor] = theme.link
                if theme.style == .prompt { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        padInlineCode(out, theme: theme)
        return out
    }
}

@MainActor
private func padInlineCode(_ text: NSMutableAttributedString, theme: MarkdownTheme) {
    // Room for the fill on either side of inline code: kerning after the character before it and
    // after its last character, so its neighbors don't touch the fill.
    let pad = 4 * theme.scale
    text.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: text.length)) { value, run, _ in
        guard value != nil, run.length > 0 else { return }
        if run.location > 0 { text.addAttribute(.kern, value: pad, range: NSRange(location: run.location - 1, length: 1)) }
        text.addAttribute(.kern, value: pad, range: NSRange(location: run.location + run.length - 1, length: 1))
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
    var italic: NSFont {
        let converted = NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
        // The system font has no italic face in some weights; a slant reads as one.
        return converted.fontDescriptor.symbolicTraits.contains(.italic) ? converted
            : NSFont(descriptor: fontDescriptor.withMatrix(AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)), size: pointSize) ?? self
    }
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var withMonospacedDigits: NSFont { .monospacedDigitSystemFont(ofSize: pointSize, weight: .regular) }
}

// MARK: - The view

/// A read-only TextKit 1 text view: TextKit 1 for its text tables and its background drawing,
/// which code blocks, quotes and rules use. Copy puts plain text on the pasteboard.
final class MarkdownNSTextView: NSTextView {
    var theme = MarkdownTheme(style: .reply, scale: 1, increasedContrast: false)
    /// Sizes measured, by width: SwiftUI asks about a few, the same ones again and again.
    private var measured: [CGFloat: CGSize] = [:]
    /// Each code block's Copy button, by where its block starts.
    private var copyButtons: [NSHostingView<CodeCopyButton>] = []
    private var copyButtonSize: CGSize?

    static func make() -> MarkdownNSTextView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        // Its width is the one it was measured at (`measure`), not the frame's: SwiftUI rounds the
        // frame to pixels, and tracking it laid the whole text out a second time per resize step.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = MarkdownNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.usesFindBar = false
        view.isAutomaticLinkDetectionEnabled = false
        view.displaysLinkToolTips = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    /// The text's size laid out at `width`: its height, and, for a bubble, its widest line.
    func measure(width: CGFloat, natural: Bool = false) -> CGSize {
        let key = natural ? -1 : width
        if let size = measured[key] { return size }
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return .zero }
        // A width too narrow to hold a word (a stack asking how far it can shrink) isn't laid out:
        // a line a letter wide is the most expensive layout there is, and it's never shown.
        if width < theme.body.pointSize * 2 {
            return CGSize(width: width, height: theme.body.pointSize * 10)
        }
        let drawn = container.size.width
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        var height = used.maxY + textContainerInset.height
        // A code block at the end draws its foot below its last line.
        if storage.length > 0,
           let decoration = storage.attribute(.markdownDecoration, at: storage.length - 1, effectiveRange: nil) as? MarkdownDecoration,
           case .code = decoration.kind {
            height += theme.codeBottom
        }
        // A table's last row draws its padding and border below its text.
        if storage.length > 0,
           let decoration = storage.attribute(.markdownDecoration, at: storage.length - 1, effectiveRange: nil) as? MarkdownDecoration,
           case .table = decoration.kind {
            height += 6 * theme.scale
        }
        height = ceil(max(height, theme.body.pointSize))
        var size = CGSize(width: width, height: height)
        // A bubble hugs its widest line, unless a box (code, a table) spans it; the glyphs' own
        // bounds, since in a window the used rect can span the container, and a point to spare.
        if theme.style == .prompt || natural {
            let glyphs = layout.glyphRange(for: container)
            let textWidth = ceil(glyphs.length > 0 ? min(layout.boundingRect(forGlyphRange: glyphs, in: container).maxX + 2, used.width) : 0)
            let box = Self.hasBox(storage)
            size.width = natural ? textWidth + (box ? 2 * theme.codeInset : 0) : box ? width : textWidth
        }
        // The unwrapped size is a question, not the width it will be drawn at: the drawn layout is
        // put back. (Any other width is usually the next frame's, so it stays laid out.)
        if natural, drawn > 0 { container.size = NSSize(width: drawn, height: .greatestFiniteMagnitude) }
        if measured.count > 8 { measured = [:] }
        measured[key] = size
        return size
    }

    /// SwiftUI may ask about other widths than the one the view ends up at; it's laid out again at
    /// its own width before it's drawn, not after each question.
    override func viewWillDraw() {
        // A bubble hugs its text, narrower than it was measured at: laid out again at that width,
        // a line could wrap differently from the one measured.
        let hugs = theme.style == .prompt && bounds.width <= (textContainer?.size.width ?? 0)
        if let container = textContainer, bounds.width > 0, !hugs, abs(container.size.width - bounds.width) >= 1 {
            container.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
        // Copy buttons follow their code boxes, placed as the text is drawn rather than by asking
        // for a layout pass of their own.
        placeCopyButtons()
        super.viewWillDraw()
    }

    func textChanged() {
        // TextKit gives the first paragraph no spacing before it, so a message starting with code
        // makes room for the box's header with an inset instead.
        let top = startsWithCode ? theme.codeHeader : 0
        if textContainerInset.height != top { textContainerInset = NSSize(width: 0, height: top) }
        measured = [:]
        // No layout asked for: the text is set while SwiftUI sizes the view, and a new value is
        // sized again anyway. Asking from inside its layout kept rows being laid out and rebuilt.
        needsDisplay = true
    }

    private static func hasBox(_ storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(.markdownDecoration, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let decoration = value as? MarkdownDecoration else { return }
            switch decoration.kind {
            case .code, .table, .rule: found = true; stop.pointee = true
            case .quote: break
            }
        }
        return found
    }

    private var startsWithCode: Bool {
        guard let storage = textStorage, storage.length > 0,
              let decoration = storage.attribute(.markdownDecoration, at: 0, effectiveRange: nil) as? MarkdownDecoration,
              case .code = decoration.kind else { return false }
        return true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager as? MarkdownLayoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        // Generous, so a box whose header or foot is in `rect` is drawn though its text isn't.
        let area = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -theme.codeHeader - theme.codeBottom)
        let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
        layout.drawDecorations(forGlyphRange: glyphs, at: origin)
    }

    // The transcript scrolls itself. A text view scrolls its selection into view after laying
    // out again, which took a resize to the start of whatever reply had the selection (or none).
    override func scrollRangeToVisible(_ range: NSRange) {}
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }

    // Copy as plain text: list markers as "• ", table cells tab-separated, rules as nothing.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map(\.rangeValue).map { Self.plain(storage, in: $0) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }

    static func plain(_ storage: NSAttributedString, in range: NSRange) -> String {
        var out = ""
        storage.enumerateAttribute(.markdownCopyAs, in: range) { value, run, _ in
            if let replacement = value as? String {
                // A marker's characters are replaced once, not once per character.
                var effective = NSRange()
                _ = storage.attribute(.markdownCopyAs, at: run.location, longestEffectiveRange: &effective,
                                      in: NSRange(location: 0, length: storage.length))
                if replacement == "\t" || replacement == "\n" {
                    // Once per character: adjacent empty cells are one run.
                    out += String(repeating: replacement, count: run.length)
                } else if run.location == effective.location || run.location == range.location {
                    out += replacement
                }
            } else {
                out += (storage.string as NSString).substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }

    // MARK: VoiceOver

    /// The reply's headings, as VoiceOver's headings rotor steps through them.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        guard let storage = textStorage, storage.length > 0, !headingRanges.isEmpty else { return super.accessibilityCustomRotors() }
        return super.accessibilityCustomRotors() + [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)]
    }

    var headingRanges: [NSRange] {
        guard let storage = textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.markdownHeading, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    // MARK: Code blocks' Copy buttons

    private func placeCopyButtons() {
        guard let layout = layoutManager as? MarkdownLayoutManager, let container = textContainer else { return }
        let blocks = layout.codeBlocks(in: container)
        while copyButtons.count > blocks.count { copyButtons.removeLast().removeFromSuperview() }
        for (i, block) in blocks.enumerated() {
            let button: NSHostingView<CodeCopyButton>
            if i < copyButtons.count {
                button = copyButtons[i]
                let root = CodeCopyButton(code: block.source, prompt: theme.style == .prompt)
                if button.rootView.code != root.code || button.rootView.prompt != root.prompt { button.rootView = root }
            } else {
                button = NSHostingView(rootView: CodeCopyButton(code: block.source, prompt: theme.style == .prompt))
                button.sizingOptions = [.intrinsicContentSize]
                addSubview(button)
                copyButtons.append(button)
            }
            // Measured once: a hosting view's fitting size is a layout pass of its own.
            if copyButtonSize == nil { copyButtonSize = button.fittingSize }
            let size = copyButtonSize ?? button.fittingSize
            let box = block.rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            button.frame = NSRect(x: box.maxX - size.width - 6 * theme.scale,
                                  y: box.minY + (theme.codeHeader - size.height) / 2,
                                  width: size.width, height: size.height)
        }
    }
}

extension MarkdownNSTextView: @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let ranges = headingRanges
        let current = parameters.currentItem?.targetRange.location
        let next: NSRange? = switch parameters.searchDirection {
        case .next: ranges.first { current == nil || $0.location > current! }
        case .previous: ranges.last { current == nil || $0.location < current! }
        @unknown default: nil
        }
        guard let next, let storage = textStorage else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = next
        result.customLabel = (storage.string as NSString).substring(with: next)
        return result
    }
}

/// A code block's Copy, in its header.
struct CodeCopyButton: View {
    let code: String
    var prompt = false

    var body: some View {
        CopyButton { Clipboard.copy(code) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(prompt ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            .help("Copy Code")
            .accessibilityIdentifier("code.copy")
    }
}

/// Draws what text attributes can't: code blocks' boxes and headers, quotes' bars, rules, tables'
/// fills and inline code's rounded fills, behind the text.
final class MarkdownLayoutManager: NSLayoutManager {
    struct CodeBlock {
        let rect: NSRect
        let language: String
        let source: String
    }

    private var theme: MarkdownTheme {
        (firstTextView as? MarkdownNSTextView)?.theme ?? MarkdownTheme(style: .reply, scale: 1, increasedContrast: false)
    }

    /// The rect of every line of the characters in `range`, joined.
    private func rect(for range: NSRange, in container: NSTextContainer) -> NSRect {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var union = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in union = union.union(used) }
        return union
    }

    /// The decorated blocks among `glyphsToShow`, each with its whole range.
    private func decorations(near glyphsToShow: NSRange) -> [(MarkdownDecoration, NSRange)] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var found: [(MarkdownDecoration, NSRange)] = []
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.markdownDecoration, in: chars) { value, run, _ in
            guard let decoration = value as? MarkdownDecoration, seen.insert(ObjectIdentifier(decoration)).inserted else { return }
            var whole = NSRange()
            _ = storage.attribute(.markdownDecoration, at: run.location, longestEffectiveRange: &whole,
                                  in: NSRange(location: 0, length: storage.length))
            found.append((decoration, whole))
        }
        return found
    }

    func codeBlocks(in container: NSTextContainer) -> [CodeBlock] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let theme = theme
        var blocks: [CodeBlock] = []
        storage.enumerateAttribute(.markdownDecoration, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let decoration = value as? MarkdownDecoration, case .code(let language, let source) = decoration.kind else { return }
            blocks.append(CodeBlock(rect: codeRect(for: range, in: container, theme: theme), language: language, source: source))
        }
        return blocks
    }

    private func codeRect(for range: NSRange, in container: NSTextContainer, theme: MarkdownTheme) -> NSRect {
        let lines = rect(for: range, in: container)
        return NSRect(x: 0, y: lines.minY - theme.codeHeader, width: container.size.width,
                      height: lines.height + theme.codeHeader + theme.codeBottom)
    }

    /// Drawn by the view under the text and its selection, rather than in the layout manager's
    /// background pass, which the text view clips to its container: a box's header is above it.
    func drawDecorations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let container = textContainers.first, let storage = textStorage else { return }
        let theme = theme
        for (decoration, range) in decorations(near: glyphsToShow) {
            switch decoration.kind {
            case .code(let language, _):
                let box = codeRect(for: range, in: container, theme: theme).offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                theme.codeFill.setFill()
                path.fill()
                theme.codeStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
                let label = language.isEmpty ? "Code" : language
                let attributes: [NSAttributedString.Key: Any] = [.font: theme.caption, .foregroundColor: theme.secondary]
                let size = (label as NSString).size(withAttributes: attributes)
                (label as NSString).draw(at: NSPoint(x: box.minX + theme.codeInset, y: box.minY + (theme.codeHeader - size.height) / 2),
                                         withAttributes: attributes)
            case .quote:
                let lines = rect(for: range, in: container).offsetBy(dx: origin.x, dy: origin.y)
                theme.quoteBar.setFill()
                NSBezierPath(roundedRect: NSRect(x: origin.x, y: lines.minY, width: 3 * theme.scale, height: lines.height),
                             xRadius: 1.5, yRadius: 1.5).fill()
            case .rule:
                let lines = rect(for: range, in: container).offsetBy(dx: origin.x, dy: origin.y)
                theme.rule.setFill()
                NSRect(x: origin.x, y: lines.midY.rounded(), width: container.size.width, height: 1).fill()
            case .table:
                // The cells' own bounds, joined: the table as TextKit laid it out.
                var table = NSRect.null
                storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
                    guard let block = (value as? NSParagraphStyle)?.textBlocks.first else { return }
                    let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
                    table = table.union(boundsRect(for: block, glyphRange: glyphs))
                }
                guard !table.isNull else { break }
                theme.tableFill.setFill()
                NSBezierPath(roundedRect: table.offsetBy(dx: origin.x, dy: origin.y), xRadius: 6, yRadius: 6).fill()
            }
        }
        // Inline code on a rounded fill.
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownInlineCode, in: chars) { value, run, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                theme.inlineCodeFill.setFill()
                // The kerning after its last character is inside the rect; keep the fill off it.
                var fill = rect.offsetBy(dx: origin.x, dy: origin.y)
                fill.origin.x -= 3 * theme.scale
                fill.size.width += 3 * theme.scale - 1 * theme.scale
                NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}
