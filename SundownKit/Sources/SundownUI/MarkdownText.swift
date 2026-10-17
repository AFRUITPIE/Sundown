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
/// Its text is built from the Markdown (`MarkdownBuilder`); a streamed reply builds only its tail
/// (`MarkdownStream`), and new text fades in.
struct MarkdownView: NSViewRepresentable {
    let text: String
    /// Whether this is the reply being streamed into: only then does new text fade in. Every
    /// settled reply, and every other use, draws its text at once.
    var streams = false
    /// A reply's colors, or a prompt's in its bubble.
    var style: MarkdownStyle = .reply

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
        context.coordinator.apply(text, theme: theme, streams: streams)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownNSTextView, context: Context) -> CGSize? {
        setText(of: nsView, context)
        guard let width = proposal.width, width.isFinite else {
            // Its ideal size: the text unwrapped.
            return nsView.measure(width: 10_000, natural: true)
        }
        let size = nsView.measure(width: max(width, 1))
        // A prompt's bubble hugs its text; a reply takes the column.
        return CGSize(width: style == .prompt ? min(width, size.width) : width, height: size.height)
    }

    static func dismantleNSView(_ view: MarkdownNSTextView, coordinator: Coordinator) {
        coordinator.stopFading()
    }

    /// Builds replies off the main actor and keeps their text, so their rows find it built: a chat
    /// opening, or an older page going in above the reader, otherwise built each reply in its row
    /// on the main thread. Pass a page of replies, not a whole long chat's: what's kept is bounded.
    static func prewarm(_ texts: [String], theme: MarkdownTheme) async {
        var seen = Set<String>()
        let fresh = texts.filter { Coordinator.built($0, theme: theme) == nil && seen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        for (text, built) in zip(fresh, await buildAll(fresh, theme: theme)) { Coordinator.keep(built, for: text, theme: theme) }
    }

    /// Each message's text, stopping early if the caller has gone.
    @concurrent
    private nonisolated static func buildAll(_ texts: [String], theme: MarkdownTheme) async -> [NSAttributedString] {
        var out: [NSAttributedString] = []
        for text in texts {
            if Task.isCancelled { break }
            out.append(MarkdownBuilder.build(text, theme: theme))
        }
        return out
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: MarkdownNSTextView?
        var openURL: OpenURLAction?
        private var theme: MarkdownTheme?
        /// What the storage was built from, and how much of it is settled.
        private var stream = MarkdownStream()
        private var fades: [(range: NSRange, start: CFTimeInterval)] = []
        private var displayLink: CADisplayLink?

        /// Whole settled messages already built, so a row scrolled back into view, a chat reopened or
        /// a reply prewarmed sets its text at once. Bounded by size too: a long chat's replies are
        /// megabytes.
        private static let settled: NSCache<NSString, NSAttributedString> = {
            let cache = NSCache<NSString, NSAttributedString>()
            cache.countLimit = 300
            cache.totalCostLimit = 8 << 20
            return cache
        }()

        private static func key(_ text: String, _ theme: MarkdownTheme) -> NSString {
            "\(theme.cacheKey)|\(NSFont.preferredFont(forTextStyle: .body).pointSize)|\(text)" as NSString
        }

        static func built(_ text: String, theme: MarkdownTheme) -> NSAttributedString? {
            settled.object(forKey: key(text, theme))
        }

        static func keep(_ built: NSAttributedString, for text: String, theme: MarkdownTheme) {
            settled.setObject(built, forKey: key(text, theme), cost: built.length * 2)
        }

        func apply(_ text: String, theme: MarkdownTheme, streams: Bool) {
            guard let view, let storage = view.textStorage else { return }
            if theme != self.theme {
                self.theme = theme
                stream = MarkdownStream()
                storage.setAttributedString(NSAttributedString())
            }
            if storage.length == 0, !streams, text != stream.source, let cached = Self.built(text, theme: theme) {
                storage.setAttributedString(cached)
                stream = MarkdownStream(source: text)
                highlighted = nil
                view.textChanged()
                return
            }
            guard let (start, old) = stream.update(storage, to: text, theme: theme, streaming: streams) else {
                // A streamed reply has arrived: its text is the settled text.
                if !streams, unkept { keep(text, theme) }
                return
            }
            // Find's marks went with the text they were on.
            highlighted = nil
            unkept = streams
            if streams {
                // What's new is whatever follows the text both versions share. A fade reaching past
                // that point goes on over what's left of its text; the new text loses whatever
                // fade it took from the text it replaced (left there, a word's end stayed
                // invisible once the reply had settled), and fades in afresh.
                let new = (storage.string as NSString).substring(from: start)
                let shared = (old as NSString).commonPrefix(with: new, options: .literal).utf16.count
                let cut = start + shared
                fades = fades.compactMap { fade in
                    let end = min(fade.range.location + fade.range.length, cut)
                    return end > fade.range.location ? (NSRange(location: fade.range.location, length: end - fade.range.location), fade.start) : nil
                }
                let range = NSRange(location: cut, length: storage.length - cut)
                if range.length > 0 {
                    view.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                    fade(range)
                }
            } else {
                keep(text, theme)
            }
            view.textChanged()
        }

        /// Whether the text was streamed and not kept yet: each length of a streaming reply would
        /// be a key never looked up again.
        private var unkept = false

        private func keep(_ text: String, _ theme: MarkdownTheme) {
            guard let storage = view?.textStorage else { return }
            unkept = false
            stopFading()
            Self.keep(storage.copy() as! NSAttributedString, for: text, theme: theme)
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

    /// The reply style at the standard size: what a view uses before it is given its theme.
    static let standard = MarkdownTheme(style: .reply, scale: 1, increasedContrast: false)

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
}

/// One drawn block: the same object across its characters, so its whole range can be found.
final class MarkdownDecoration: NSObject {
    enum Kind: Equatable { case code(language: String, source: String), quote, table, rule }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

// MARK: - The view

/// A read-only TextKit 1 text view: TextKit 1 for its text tables and its background drawing,
/// which code blocks, quotes and rules use. Copy puts plain text on the pasteboard.
final class MarkdownNSTextView: NSTextView {
    var theme = MarkdownTheme.standard {
        didSet { (layoutManager as? MarkdownLayoutManager)?.theme = theme }
    }
    /// Sizes measured, by width: SwiftUI asks about a few, the same ones again and again.
    private var measured: [CGFloat: CGSize] = [:]
    /// A Copy button for each code block, in the blocks' order.
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
        // A code block at the end draws its foot below its last line, and a table's last row its
        // padding and border below its text.
        switch decorationKind(at: storage.length - 1) {
        case .code: height += theme.codeBottom
        case .table: height += 6 * theme.scale
        default: break
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

    /// The kind of block drawn at a character of the text, if any.
    private func decorationKind(at index: Int) -> MarkdownDecoration.Kind? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return (storage.attribute(.markdownDecoration, at: index, effectiveRange: nil) as? MarkdownDecoration)?.kind
    }

    private var startsWithCode: Bool {
        if case .code? = decorationKind(at: 0) { true } else { false }
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
        let text = selectedRanges.map(\.rangeValue).map { MarkdownBuilder.plain(storage, in: $0) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
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
        let source: String
    }

    /// Its text view's, which the view hands it as it changes.
    var theme = MarkdownTheme.standard

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
            guard let decoration = value as? MarkdownDecoration, case .code(_, let source) = decoration.kind else { return }
            blocks.append(CodeBlock(rect: codeRect(for: range, in: container, theme: theme), source: source))
        }
        return blocks
    }

    private func codeRect(for range: NSRange, in container: NSTextContainer, theme: MarkdownTheme) -> NSRect {
        let lines = rect(for: range, in: container)
        // Inside a list item, the box starts where the item's text does.
        let x = max(0, headIndent(at: range.location) - theme.codeInset)
        return NSRect(x: x, y: lines.minY - theme.codeHeader, width: container.size.width - x,
                      height: lines.height + theme.codeHeader + theme.codeBottom)
    }

    /// The indent of the paragraph holding a character.
    private func headIndent(at index: Int) -> CGFloat {
        guard let storage = textStorage, index < storage.length else { return 0 }
        return (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
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
                let x = origin.x + max(0, headIndent(at: range.location) - theme.quoteIndent)
                NSBezierPath(roundedRect: NSRect(x: x, y: lines.minY, width: 3 * theme.scale, height: lines.height),
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
