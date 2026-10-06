import Foundation

/// Typing Markdown as an editor helps with it (VS Code, Obsidian, Bear): a new line continues the
/// list or quote it's in, an empty item ends it, Tab and Shift-Tab nest an item, and a selection
/// can be wrapped in emphasis, code or a link. Pure edits on the text, in UTF-16 offsets as
/// `NSTextView` counts them, so the field applies each as one undoable change.
enum ComposerEditing {
    /// Replace `range` with `text`, then select `selection`.
    struct Edit: Equatable {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    /// A line's Markdown prefix: its indent, then a quote's ">", a list's marker and a task's box.
    struct Prefix: Equatable {
        var indent: String
        /// "> ", "- ", "1. " and so on, with its space; empty for a plain line.
        var marker: String
        /// "[ ] " or "[x] ", after a list marker.
        var task: String
        var length: Int { (indent + marker + task).utf16.count }
        var isList: Bool { !marker.isEmpty && !marker.hasPrefix(">") }

        /// The prefix the next line starts with: the next number, an unchecked box.
        var next: String {
            var marker = marker
            if let number = Int(marker.prefix { $0.isNumber }) {
                marker = "\(number + 1)" + marker.drop { $0.isNumber }
            }
            return indent + marker + (task.isEmpty ? "" : "[ ] ")
        }
    }

    nonisolated static func prefix(of line: Substring) -> Prefix {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        var rest = line.dropFirst(indent.count)
        var marker = ""
        if rest.hasPrefix("> ") || rest == ">" {
            marker = rest.hasPrefix("> ") ? "> " : ">"
        } else if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "\(first) "
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let after = rest.dropFirst(digits.count)
            if !digits.isEmpty, digits.count <= 9, let delimiter = after.first, delimiter == "." || delimiter == ")",
               after.dropFirst().first == " " {
                marker = "\(digits)\(delimiter) "
            }
        }
        rest = rest.dropFirst(marker.count)
        var task = ""
        if !marker.isEmpty, !marker.hasPrefix(">"), rest.count >= 4, rest.hasPrefix("["),
           " xX".contains(rest.dropFirst().first!), rest.dropFirst(2).hasPrefix("] ") {
            task = String(rest.prefix(4))
        }
        return Prefix(indent: String(indent), marker: marker, task: task)
    }

    /// The line around `location`: its range, without its newline.
    nonisolated static func lineRange(in text: NSString, at location: Int) -> NSRange {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// A new line at the selection: the list, task list or quote continues, with the next number;
    /// an empty item ends the list (or steps out a level); otherwise the line's indent carries on.
    nonisolated static func newLine(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let line = lineRange(in: ns, at: selection.location)
        let prefix = prefix(of: Substring(ns.substring(with: line)))
        let plain = Edit(range: selection, text: "\n" + prefix.indent,
                         selection: NSRange(location: selection.location + 1 + prefix.indent.utf16.count, length: 0))
        guard !prefix.marker.isEmpty, selection.location >= line.location + prefix.length else { return plain }
        let isEmpty = line.length == prefix.length || ns.substring(with: line).trimmingCharacters(in: .whitespaces) == prefix.marker.trimmingCharacters(in: .whitespaces)
        if isEmpty, selection.length == 0 {
            // An empty item ends the list: out a level if it's nested, else the marker goes.
            let replacement = prefix.indent.isEmpty ? "" : outdented(prefix.indent, by: prefix) + prefix.marker + prefix.task
            return Edit(range: line, text: replacement,
                        selection: NSRange(location: line.location + replacement.utf16.count, length: 0))
        }
        let next = "\n" + prefix.next
        return Edit(range: selection, text: next, selection: NSRange(location: selection.location + next.utf16.count, length: 0))
    }

    /// How far a nested item steps in: past its parent's marker, so it nests in Markdown.
    private nonisolated static func step(_ prefix: Prefix) -> Int { max(prefix.marker.count, 2) }

    private nonisolated static func outdented(_ indent: String, by prefix: Prefix) -> String {
        String(indent.dropLast(min(step(prefix), indent.count)))
    }

    /// Tab (in) or Shift-Tab (out) on the list items the selection touches; nil off a list.
    nonisolated static func indent(in text: String, selection: NSRange, outward: Bool) -> Edit? {
        let ns = text as NSString
        let lines = ns.lineRange(for: selection)
        var result = ""
        var delta = 0, firstDelta = 0
        var touched = false
        var location = lines.location
        while location < NSMaxRange(lines) {
            let line = lineRange(in: ns, at: location)
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            let prefix = prefix(of: Substring(content))
            var newContent = content
            if prefix.isList {
                touched = true
                if outward {
                    let remove = min(step(prefix), prefix.indent.count)
                    newContent = String(content.dropFirst(remove))
                } else {
                    newContent = String(repeating: " ", count: step(prefix)) + content
                }
            }
            let change = newContent.utf16.count - content.utf16.count
            if location == lines.location { firstDelta = change }
            delta += change
            result += newContent + ns.substring(with: NSRange(location: NSMaxRange(line), length: NSMaxRange(full) - NSMaxRange(line)))
            location = NSMaxRange(full)
        }
        guard touched else { return nil }
        // The caret, or the selection's ends, move with their lines' text.
        let start = max(lines.location, selection.location + firstDelta)
        let end = max(start, NSMaxRange(selection) + (selection.length == 0 ? firstDelta : delta))
        return Edit(range: lines, text: result, selection: NSRange(location: start, length: end - start))
    }

    /// The selection wrapped in `open` and `close`, still selected inside them; or, when it's
    /// already wrapped so, unwrapped. With nothing selected, the pair with the caret between.
    nonisolated static func wrap(in text: String, selection: NSRange, open: String, close: String) -> Edit {
        let ns = text as NSString
        let inner = ns.substring(with: selection)
        let o = open.utf16.count, c = close.utf16.count
        // Already wrapped, just outside the selection: take the pair away. Asterisks are counted,
        // so italic inside bold ("***x***") comes off on its own.
        var wrapped = selection.location >= o && NSMaxRange(selection) + c <= ns.length
            && ns.substring(with: NSRange(location: selection.location - o, length: o)) == open
            && ns.substring(with: NSRange(location: NSMaxRange(selection), length: c)) == close
        if wrapped, open.allSatisfy({ $0 == "*" }) {
            func run(_ step: Int, from start: Int) -> Int {
                var count = 0, i = start
                while i >= 0, i < ns.length, ns.character(at: i) == 42 { count += 1; i += step }
                return count
            }
            let stars = min(run(-1, from: selection.location - 1), run(1, from: NSMaxRange(selection)))
            wrapped = open.count == 1 ? stars % 2 == 1 : stars >= 2
        }
        if wrapped {
            return Edit(range: NSRange(location: selection.location - o, length: selection.length + o + c), text: inner,
                        selection: NSRange(location: selection.location - o, length: selection.length))
        }
        return Edit(range: selection, text: open + inner + close,
                    selection: NSRange(location: selection.location + o, length: selection.length))
    }

    /// A link around the selection: "[selection](url)". Without an address yet, the caret waits
    /// between the parentheses for one, or between the brackets when nothing was selected.
    nonisolated static func link(in text: String, selection: NSRange, url: String? = nil) -> Edit {
        let inner = (text as NSString).substring(with: selection)
        let replacement = "[\(inner)](\(url ?? ""))"
        let caret = url != nil ? replacement.utf16.count
            : inner.isEmpty ? 1 : replacement.utf16.count - 1
        return Edit(range: selection, text: replacement, selection: NSRange(location: selection.location + caret, length: 0))
    }

    /// Characters that, typed over a selection, wrap it rather than replace it, as VS Code does.
    nonisolated static let surroundingPairs: [String: String] = [
        "*": "*", "_": "_", "`": "`", "~": "~", "=": "=", "[": "]", "(": ")", "\"": "\"",
    ]

    /// Whether `string` is a lone web address, which pasted over a selection makes it a link.
    nonisolated static func isURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https" || scheme == "mailto") && url.host() != nil || scheme == "mailto"
    }
}
