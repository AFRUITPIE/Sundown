import SwiftUI

/// The message field as Markdown styled as it's typed (Settings ▸ Advanced ▸ Composer ▸ Live
/// Markdown): bold, italic, code, headings, quotes and links look like themselves while their
/// markers stay, dimmed, so the text is still exactly what's sent. A `TextEditor` over an
/// `AttributedString` whose characters are the draft; only attributes change, and the system's own
/// formatting controls are hidden, so Markdown is the only way to format.
struct LiveMarkdownField: View {
    @Binding var text: String
    let placeholder: String
    @State private var styled = AttributedString()
    @State private var selection = AttributedTextSelection()
    @Environment(\.textScale) private var scale

    var body: some View {
        // Sized by its text, one line to twelve, as the plain field grows: a hidden copy of the text
        // sets the size and the editor is laid over it, since a text editor takes all the height it's
        // offered. The copy is inset as the editor's text is (its line fragment padding), so both wrap
        // at the same width.
        Text(sizing)
            .lineLimit(1...12)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                TextEditor(text: $styled, selection: $selection)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .textInputFormattingControlVisibility(.hidden, for: .all)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onAppear { restyle(from: text) }
            // Typing: the draft follows the characters, and the styles follow the draft.
            .onChange(of: styled) { old, new in
                let plain = String(new.characters)
                guard plain != String(old.characters) else { return }
                if plain != text { text = plain }
                restyle()
            }
            // From outside (sent and cleared, a draft put in by Shortcuts, a mention inserted).
            .onChange(of: text) { _, new in
                guard new != String(styled.characters) else { return }
                restyle(from: new)
                selection = AttributedTextSelection(range: styled.endIndex..<styled.endIndex)
            }
            .onChange(of: scale) { restyle() }
    }

    /// The text as the size is measured from: a line's height when it's empty or ends in a new line,
    /// which `Text` otherwise doesn't count.
    private var sizing: AttributedString {
        var text = styled
        if text.characters.isEmpty || text.characters.last == "\n" { text.append(AttributedString(" ")) }
        return text
    }

    /// New text, styled; the selection is set by the caller.
    private func restyle(from plain: String) {
        styled = AttributedString(plain)
        restyle()
    }

    /// The styles for the characters as they are, applied in place so the selection stays put.
    private func restyle() {
        styled.transform(updating: &selection) { LiveMarkdown.style(&$0, scale: scale) }
    }
}

/// Where Markdown's syntax is in a draft, for `LiveMarkdownField`: what to style, never a change to
/// the text. Line by line, and small on purpose: a draft is short, and a style that's slightly off
/// is harmless where a rewritten character wouldn't be.
enum LiveMarkdown {
    enum Style: Equatable {
        /// Syntax itself: `**`, `#`, a code fence, a link's target.
        case marker
        case strong
        case emphasis
        case code
        case codeBlock
        case heading(Int)
        case quote
        case link
    }

    struct Span: Equatable {
        let range: Range<String.Index>
        let style: Style
    }

    /// `text`'s attributes set for its syntax; its characters left as they are.
    static func style(_ text: inout AttributedString, scale: CGFloat) {
        let plain = String(text.characters)
        let all = text.startIndex..<text.endIndex
        text[all].font = nil
        text[all].foregroundColor = nil
        text[all].backgroundColor = nil
        func font(_ textStyle: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
            .system(textStyle, design: design, weight: weight).scaled(by: scale)
        }
        for span in spans(in: plain) {
            guard let range = Range(span.range, in: text) else { continue }
            switch span.style {
            case .marker: text[range].foregroundColor = .secondary
            case .strong: text[range].font = font(.body, weight: .bold)
            case .emphasis: text[range].font = font(.body).italic()
            case .code:
                text[range].font = font(.body, design: .monospaced)
                text[range].backgroundColor = Color.secondary.opacity(0.12)
            case .codeBlock: text[range].font = font(.body, design: .monospaced)
            case .heading(let level): text[range].font = font(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold)
            case .quote: text[range].foregroundColor = .secondary
            case .link: text[range].foregroundColor = .accentColor
            }
        }
    }

    static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        var inFence = false
        var lineStart = text.startIndex
        while true {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if line.hasPrefix("```") {
                spans.append(Span(range: line.startIndex..<line.endIndex, style: .marker))
                inFence.toggle()
            } else if inFence {
                if !line.isEmpty { spans.append(Span(range: line.startIndex..<line.endIndex, style: .codeBlock)) }
            } else {
                spans += block(line)
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return spans
    }

    /// One line outside a code fence: a heading or a quote, then its inline syntax.
    private static func block(_ line: Substring) -> [Span] {
        var spans: [Span] = []
        var body = line
        if let m = line.prefixMatch(of: #/(#{1,6}) /#) {
            let hashes = m.output.1
            spans.append(Span(range: line.startIndex..<m.range.upperBound, style: .marker))
            if m.range.upperBound < line.endIndex {
                spans.append(Span(range: m.range.upperBound..<line.endIndex, style: .heading(hashes.count)))
            }
            body = line[m.range.upperBound...]
        } else if let m = line.prefixMatch(of: #/> ?/#) {
            spans.append(Span(range: m.range, style: .marker))
            if m.range.upperBound < line.endIndex {
                spans.append(Span(range: m.range.upperBound..<line.endIndex, style: .quote))
            }
            body = line[m.range.upperBound...]
        }
        return spans + inline(body)
    }

    /// Code spans first, since nothing inside one is syntax; then links, bold and italic around them.
    private static func inline(_ text: Substring) -> [Span] {
        var spans: [Span] = []
        var code: [Range<String.Index>] = []
        for m in text.matches(of: /`([^`\n]+)`/) {
            code.append(m.range)
            spans.append(Span(range: m.range.lowerBound..<m.output.1.startIndex, style: .marker))
            spans.append(Span(range: m.output.1.startIndex..<m.output.1.endIndex, style: .code))
            spans.append(Span(range: m.output.1.endIndex..<m.range.upperBound, style: .marker))
        }
        func free(_ r: Range<String.Index>) -> Bool { !code.contains { $0.overlaps(r) } }
        func wrapped(_ m: Regex<(Substring, Substring)>.Match, inner style: Style) {
            guard free(m.range) else { return }
            let inner = m.output.1
            spans.append(Span(range: m.range.lowerBound..<inner.startIndex, style: .marker))
            spans.append(Span(range: inner.startIndex..<inner.endIndex, style: style))
            spans.append(Span(range: inner.endIndex..<m.range.upperBound, style: .marker))
        }
        for m in text.matches(of: /\[([^\]\n]+)\]\([^)\s]+\)/) { wrapped(m, inner: .link) }
        for m in text.matches(of: /\*\*([^*\n]+)\*\*/) { wrapped(m, inner: .strong) }
        for m in text.matches(of: /__([^_\n]+)__/) { wrapped(m, inner: .strong) }
        // Single markers, not the halves of a double one (`**`) nor inside a word (`snake_case`).
        func around(_ m: Regex<(Substring, Substring)>.Match, isNot excluded: (Character) -> Bool) -> Bool {
            let before = m.range.lowerBound > text.startIndex ? text[text.index(before: m.range.lowerBound)] : nil
            let after = m.range.upperBound < text.endIndex ? text[m.range.upperBound] : nil
            return !(before.map(excluded) ?? false) && !(after.map(excluded) ?? false)
        }
        for m in text.matches(of: /\*([^*\s][^*\n]*?)\*/) where around(m, isNot: { $0 == "*" }) { wrapped(m, inner: .emphasis) }
        for m in text.matches(of: /_([^_\s][^_\n]*?)_/) where around(m, isNot: { $0 == "_" || $0.isLetter || $0.isNumber }) {
            wrapped(m, inner: .emphasis)
        }
        return spans
    }
}

#if DEBUG
/// Each kind of syntax, styled in the field.
#Preview("Live Markdown field") {
    @Previewable @State var text = """
    # Fix the resize jank
    Look at **the hover bar** and the *code block's* `CopyButton`.
    > Keep it native.
    See [the issue](https://github.com/AFRUITPIE/tether-app/issues/61).
    ```
    swift test --package-path TetherKit
    ```
    """
    LiveMarkdownField(text: $text, placeholder: "Message Claude")
        .scaledFont(.body)
        .padding()
        .frame(width: 520)
}

#Preview("Live Markdown field (empty)") {
    @Previewable @State var text = ""
    LiveMarkdownField(text: $text, placeholder: "Message Claude")
        .scaledFont(.body)
        .padding()
        .frame(width: 520)
}
#endif
