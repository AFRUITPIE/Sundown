import AppKit

/// The composer's Markdown, styled as it's typed: emphasis, code, headings, quotes, lists and links
/// look as they will, and their syntax stays in the text, dimmed, as in Bear or iA Writer. The
/// characters are exactly what was typed; only attributes change, so what's sent is the Markdown.
enum ComposerMarkdown {
    /// How one character is drawn.
    struct Style: Equatable {
        enum Tone: Equatable { case normal, syntax, secondary, accent }
        var bold = false
        var italic = false
        var code = false
        var strike = false
        /// 1–6 for a heading's line, 0 elsewhere.
        var heading = 0
        var tone = Tone.normal
        var fill = false
    }

    /// Each character's style, in order. Pure, so it can be tested and run on any text.
    nonisolated static func styles(for text: String) -> [Style] {
        var out: [Style] = []
        out.reserveCapacity(text.count)
        var inFence = false
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out.append(Style()) } // the newline
            first = false
            let chars = Array(line)
            var styles = [Style](repeating: Style(), count: chars.count)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                for i in styles.indices { styles[i].code = true; styles[i].tone = .syntax }
            } else if inFence {
                for i in styles.indices { styles[i].code = true }
            } else {
                block(chars, &styles)
            }
            out += styles
        }
        return out
    }

    /// A line's block syntax (heading, quote, list item), then its inline syntax.
    private nonisolated static func block(_ chars: [Character], _ styles: inout [Style]) {
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        var contentStart = i
        // A heading: one to six #, then a space.
        var hashes = 0
        while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
        if (1...6).contains(hashes), i + hashes < chars.count, chars[i + hashes] == " " {
            for k in i..<(i + hashes + 1) { styles[k].tone = .syntax }
            for k in (i + hashes + 1)..<chars.count { styles[k].heading = hashes }
            for k in i..<(i + hashes + 1) { styles[k].heading = hashes }
            contentStart = i + hashes + 1
        } else if i < chars.count, chars[i] == ">" {
            styles[i].tone = .syntax
            contentStart = i + 1
            if contentStart < chars.count, chars[contentStart] == " " { contentStart += 1 }
            for k in contentStart..<chars.count { styles[k].tone = .secondary }
        } else if let end = listMarkerEnd(chars, from: i) {
            for k in i..<end { styles[k].tone = .secondary }
            contentStart = end
            // A task's box.
            if contentStart + 3 < chars.count, chars[contentStart] == "[", chars[contentStart + 2] == "]",
               chars[contentStart + 3] == " ", " xX".contains(chars[contentStart + 1]) {
                for k in contentStart..<(contentStart + 3) { styles[k].tone = .secondary }
                contentStart += 4
            }
        }
        inline(chars, from: contentStart, to: chars.count, &styles)
    }

    /// Where a list item's marker and its space end: "- ", "* ", "+ ", "1. " or "1) ".
    private nonisolated static func listMarkerEnd(_ chars: [Character], from i: Int) -> Int? {
        guard i < chars.count else { return nil }
        if "-*+".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " { return i + 2 }
        var j = i
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
        guard j > i, j - i <= 9, j + 1 < chars.count, chars[j] == "." || chars[j] == ")", chars[j + 1] == " " else { return nil }
        return j + 2
    }

    /// The inline syntax of `c[start..<n]`, which may be part of a line: an emphasis's or a link's
    /// insides, searched without copying them.
    private nonisolated static func inline(_ c: [Character], from start: Int, to n: Int, _ styles: inout [Style]) {
        var i = start
        // Whether a delimiter run could open or close: CommonMark's flanking, simplified.
        func isWord(_ k: Int) -> Bool { k >= 0 && k < n && (c[k].isLetter || c[k].isNumber) }
        func space(_ k: Int) -> Bool { k < 0 || k >= n || c[k].isWhitespace }
        func find(_ token: [Character], from k: Int) -> Int? {
            var j = k
            outer: while j + token.count <= n {
                for (t, ch) in token.enumerated() where c[j + t] != ch { j += 1; continue outer }
                return j
            }
            return nil
        }
        while i < n {
            let ch = c[i]
            if ch == "\\", i + 1 < n, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                styles[i].tone = .syntax
                i += 2
                continue
            }
            if ch == "`" {
                var ticks = 1
                while i + ticks < n, c[i + ticks] == "`" { ticks += 1 }
                if let close = find(Array(repeating: "`", count: ticks), from: i + ticks), close > i + ticks {
                    for k in i..<(close + ticks) { styles[k].code = true }
                    for k in (i + ticks)..<close { styles[k].fill = true }
                    for k in i..<(i + ticks) { styles[k].tone = .syntax }
                    for k in close..<(close + ticks) { styles[k].tone = .syntax }
                    i = close + ticks
                    continue
                }
                i += ticks
                continue
            }
            // A link: its text up to the first "]", which must be followed by "(".
            if ch == "[", let mid = find(["]"], from: i + 1), mid > i + 1, mid + 1 < n, c[mid + 1] == "(",
               let close = find([")"], from: mid + 2) {
                styles[i].tone = .syntax
                for k in (i + 1)..<mid where styles[k].tone == .normal { styles[k].tone = .accent }
                for k in mid...close { styles[k].tone = .syntax }
                inline(c, from: i + 1, to: mid, &styles)
                i = close + 1
                continue
            }
            if ch == "h", c[i..<n].starts(with: "https://") || c[i..<n].starts(with: "http://") {
                var j = i
                while j < n, !c[j].isWhitespace { j += 1 }
                for k in i..<j { styles[k].tone = .accent }
                i = j
                continue
            }
            // An @-mention of a file, or a /command at the start.
            if (ch == "@" && space(i - 1) && i + 1 < n && !space(i + 1)) || (ch == "/" && i == start && start == 0 && i + 1 < n && c[i + 1].isLetter) {
                var j = i + 1
                while j < n, !c[j].isWhitespace { j += 1 }
                for k in i..<j { styles[k].tone = .accent }
                i = j
                continue
            }
            if ch == "*" || ch == "_" || ch == "~" {
                var run = 1
                while i + run < n, c[i + run] == ch { run += 1 }
                let width = ch == "~" ? 2 : min(run, 3)
                let opens = !space(i + run) && !(ch == "_" && isWord(i - 1))
                if (ch != "~" || run == 2), opens,
                   let close = closing(c, ch, width: width, from: i + width, to: n, space: space, isWord: isWord) {
                    for k in i..<(i + width) { styles[k].tone = .syntax }
                    for k in close..<(close + width) { styles[k].tone = .syntax }
                    for k in (i + width)..<close {
                        if ch == "~" { styles[k].strike = true }
                        else {
                            if width >= 2 { styles[k].bold = true }
                            if width != 2 { styles[k].italic = true }
                        }
                    }
                    inline(c, from: i + width, to: close, &styles)
                    i = close + width
                    continue
                }
                i += run
                continue
            }
            i += 1
        }
    }

    /// Where a run of `width` delimiters closes the one opened before `from`, on the same line.
    private nonisolated static func closing(_ c: [Character], _ ch: Character, width: Int, from: Int, to n: Int,
                                            space: (Int) -> Bool, isWord: (Int) -> Bool) -> Int? {
        var j = from
        while j + width <= n {
            if c[j] == "`" { // code spans aren't searched for closers
                var end = j + 1
                while end < n, c[end] != "`" { end += 1 }
                j = end + 1
                continue
            }
            if c[j] == ch {
                var run = 0
                while j + run < n, c[j + run] == ch { run += 1 }
                if run >= width, j > from, !space(j - 1), !(ch == "_" && isWord(j + run)) { return j + run - width }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    /// Sets every character's attributes from its style, in runs, leaving the characters alone.
    @MainActor
    static func apply(to storage: NSTextStorage, scale: CGFloat) {
        let text = storage.string
        let styles = styles(for: text)
        guard !styles.isEmpty else { return }
        // Only runs whose attributes changed are set: setting the rest would lay them out again.
        func set(_ style: Style, _ range: NSRange) {
            let wanted = attributes(style, scale: scale)
            var effective = NSRange()
            let current = storage.attributes(at: range.location, longestEffectiveRange: &effective, in: range)
            guard effective != range || !NSDictionary(dictionary: current).isEqual(to: wanted) else { return }
            storage.setAttributes(wanted, range: range)
        }
        storage.beginEditing()
        var location = 0
        var runStart = 0
        var runStyle = styles[0]
        for (i, character) in text.enumerated() {
            if styles[i] != runStyle {
                set(runStyle, NSRange(location: runStart, length: location - runStart))
                runStart = location
                runStyle = styles[i]
            }
            location += character.utf16.count
        }
        set(runStyle, NSRange(location: runStart, length: location - runStart))
        storage.endEditing()
    }

    @MainActor
    static func attributes(_ style: Style, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let size = (style.heading == 1 ? body * 1.3 : style.heading == 2 ? body * 1.15 : style.code ? body * 0.94 : body) * scale
        let weight: NSFont.Weight = style.bold || style.heading > 0 ? .bold : .regular
        var font = style.code ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        switch style.tone {
        case .normal: attributes[.foregroundColor] = NSColor.labelColor
        case .syntax: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .secondary: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .accent: attributes[.foregroundColor] = NSColor.controlAccentColor
        }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.fill { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2 * scale
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    /// One line of the field's body text: its height when empty.
    @MainActor
    static func lineHeight(scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize * scale)
        return ceil(font.ascender - font.descender + font.leading)
    }
}
