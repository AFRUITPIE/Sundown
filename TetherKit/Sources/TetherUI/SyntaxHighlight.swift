import Foundation
import SwiftUI

/// A code block's colors: comments, strings, numbers, keywords and type names, as Xcode shows them,
/// in system colors that follow the appearance and Increased Contrast. Apple has no highlighting
/// API, and the packages that do it bring JavaScriptCore or a parser per language; a shallow scan
/// is enough for reading code in a reply. Pure and nonisolated: it runs off the main actor, and
/// its result is kept (`cached`), so a block drawn again isn't scanned again.
enum SyntaxHighlight {
    enum Kind: Sendable { case comment, string, number, keyword, type }

    /// How a family of languages writes the things that get colored.
    struct Grammar: Sendable {
        var lineComment: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<UInt8> = [UInt8(ascii: "\""), UInt8(ascii: "'")]
        /// `"""` and `'''` strings, which run across lines.
        var tripleQuotes = false
        var keywords: Set<String> = []
        var caseInsensitive = false
        /// Capitalized names read as types.
        var types = true
    }

    /// Longer code is left plain: coloring it isn't worth the scan.
    static let limit = 60_000

    /// The code with its colors, or nil for a language this doesn't know.
    nonisolated static func attributed(_ code: String, language: String) -> AttributedString? {
        guard code.utf8.count <= limit, let grammar = grammar(for: language) else { return nil }
        let runs = scan(Array(code.utf8), grammar)
        var out = AttributedString()
        var index = code.startIndex
        var offset = 0
        func take(to end: Int) -> Substring {
            let next = code.utf8.index(index, offsetBy: end - offset)
            defer { index = next; offset = end }
            return code[index..<next]
        }
        for run in runs {
            if run.start > offset { out.append(AttributedString(take(to: run.start))) }
            var piece = AttributedString(take(to: run.end))
            piece.foregroundColor = color(run.kind)
            out.append(piece)
        }
        if offset < code.utf8.count { out.append(AttributedString(take(to: code.utf8.count))) }
        return out
    }

    nonisolated static func color(_ kind: Kind) -> Color {
        switch kind {
        case .comment: .secondary
        case .string: .red
        case .number: .blue
        case .keyword: .pink
        case .type: .teal
        }
    }

    struct Run: Equatable { let start: Int, end: Int, kind: Kind }

    /// The colored runs, in order, as UTF-8 offsets.
    nonisolated static func scan(_ b: [UInt8], _ g: Grammar) -> [Run] {
        var runs: [Run] = []
        var i = 0
        let n = b.count
        func starts(_ s: String, at i: Int) -> Bool {
            let u = Array(s.utf8)
            guard i + u.count <= n else { return false }
            for k in 0..<u.count where b[i + k] != u[k] { return false }
            return true
        }
        func isIdentifier(_ c: UInt8) -> Bool {
            // `$` too, so `$0` and `$HOME` read as names, not a number and a word.
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == 36 || c >= 128
        }
        while i < n {
            let c = b[i]
            // A line comment. `#` only where a word could start, so `$#` and `a#b` aren't one.
            if let marker = g.lineComment.first(where: { starts($0, at: i) }),
               marker != "#" || i == 0 || b[i - 1] == 32 || b[i - 1] == 9 || b[i - 1] == 10 {
                var j = i
                while j < n, b[j] != 10 { j += 1 }
                runs.append(.init(start: i, end: j, kind: .comment)); i = j; continue
            }
            if let block = g.blockComment, starts(block.open, at: i) {
                var j = i + block.open.utf8.count
                while j < n, !starts(block.close, at: j) { j += 1 }
                j = min(n, j + block.close.utf8.count)
                runs.append(.init(start: i, end: j, kind: .comment)); i = j; continue
            }
            if g.quotes.contains(c) {
                let triple = g.tripleQuotes && i + 2 < n && b[i + 1] == c && b[i + 2] == c
                var j = i + (triple ? 3 : 1)
                while j < n {
                    if b[j] == 92 { j += 2; continue }
                    if triple {
                        if b[j] == c, j + 2 < n, b[j + 1] == c, b[j + 2] == c { j += 3; break }
                    } else if b[j] == c { j += 1; break }
                    // An unclosed quote ends with its line: an apostrophe in a comment-less
                    // language shouldn't color the rest of the block.
                    else if b[j] == 10, c != UInt8(ascii: "`") { break }
                    j += 1
                }
                j = min(j, n)
                runs.append(.init(start: i, end: j, kind: .string)); i = j; continue
            }
            if c >= 48 && c <= 57, i == 0 || !isIdentifier(b[i - 1]) {
                var j = i + 1
                while j < n, isIdentifier(b[j]) || (b[j] == 46 && j + 1 < n && b[j + 1] >= 48 && b[j + 1] <= 57) { j += 1 }
                runs.append(.init(start: i, end: j, kind: .number)); i = j; continue
            }
            if isIdentifier(c) {
                var j = i + 1
                while j < n, isIdentifier(b[j]) { j += 1 }
                let word = String(decoding: b[i..<j], as: UTF8.self)
                if g.keywords.contains(g.caseInsensitive ? word.lowercased() : word) {
                    runs.append(.init(start: i, end: j, kind: .keyword))
                } else if g.types, c >= 65 && c <= 90, word.utf8.contains(where: { $0 >= 97 && $0 <= 122 }) {
                    runs.append(.init(start: i, end: j, kind: .type))
                }
                i = j; continue
            }
            i += 1
        }
        return runs
    }

    /// The grammar for a fence's language, or a file name's extension.
    nonisolated static func grammar(for language: String) -> Grammar? {
        var name = language.lowercased().trimmingCharacters(in: .whitespaces)
        switch name {
        case "dockerfile", "makefile", "gemfile", "podfile": return hashGrammar(shell)
        default: break
        }
        if name.contains("."), let ext = name.split(separator: ".").last { name = String(ext) }
        switch name {
        case "swift":
            var g = cLike(swift); g.tripleQuotes = true; g.quotes = [UInt8(ascii: "\"")]; return g
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
            var g = cLike(javascript); g.quotes.insert(UInt8(ascii: "`")); return g
        case "go", "golang":
            var g = cLike(go); g.quotes.insert(UInt8(ascii: "`")); return g
        case "rs", "rust": return cLike(rust)
        case "c", "h", "cpp", "cc", "cxx", "hpp", "c++", "objc", "objective-c", "m", "mm", "java", "kt", "kts",
             "kotlin", "cs", "csharp", "c#", "scala", "dart", "groovy", "gradle", "php":
            return cLike(cFamily)
        case "py", "python", "python3":
            var g = hashGrammar(python); g.tripleQuotes = true; return g
        case "rb", "ruby": return hashGrammar(ruby)
        case "sh", "bash", "zsh", "shell", "console", "fish", "command", "terminal", "ps1", "powershell":
            var g = hashGrammar(shell); g.types = false; return g
        case "yaml", "yml", "toml", "ini", "conf":
            var g = hashGrammar(["true", "false", "null", "yes", "no", "on", "off"]); g.types = false; return g
        case "json", "jsonc", "json5", "input":
            var g = cLike(["true", "false", "null"]); g.quotes = [UInt8(ascii: "\"")]; g.types = false; return g
        case "sql", "psql", "mysql", "sqlite":
            return Grammar(lineComment: ["--"], blockComment: ("/*", "*/"), keywords: sql, caseInsensitive: true, types: false)
        case "css", "scss", "less":
            return Grammar(blockComment: ("/*", "*/"), types: false)
        default: return nil
        }
    }

    private nonisolated static func cLike(_ keywords: Set<String>) -> Grammar {
        Grammar(lineComment: ["//"], blockComment: ("/*", "*/"), keywords: keywords)
    }

    private nonisolated static func hashGrammar(_ keywords: Set<String>) -> Grammar {
        Grammar(lineComment: ["#"], keywords: keywords)
    }

    private nonisolated static let swift: Set<String> = [
        "let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default",
        "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "init", "deinit", "self", "Self",
        "nil", "true", "false", "try", "catch", "throw", "throws", "rethrows", "async", "await", "actor", "some", "any",
        "where", "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating", "inout",
        "do", "is", "as", "defer", "typealias", "associatedtype", "subscript", "lazy", "weak", "unowned", "get", "set",
        "willSet", "didSet", "nonisolated", "isolated", "consuming", "borrowing", "sending", "package", "fallthrough",
    ]
    private nonisolated static let javascript: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "new", "this", "class", "extends", "super", "import", "export", "from", "as", "async",
        "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true",
        "false", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static",
        "yield", "void", "delete", "declare", "namespace", "keyof", "satisfies",
    ]
    private nonisolated static let go: Set<String> = [
        "func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer",
        "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select",
        "fallthrough", "nil", "true", "false",
    ]
    private nonisolated static let rust: Set<String> = [
        "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "self", "Self", "super",
        "match", "if", "else", "for", "while", "loop", "in", "return", "break", "continue", "as", "ref", "move",
        "const", "static", "where", "type", "async", "await", "dyn", "unsafe", "true", "false", "Some", "None", "Ok", "Err",
    ]
    private nonisolated static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof",
        "typedef", "struct", "union", "enum", "const", "static", "extern", "void", "int", "char", "float", "double",
        "long", "short", "unsigned", "signed", "bool", "boolean", "true", "false", "null", "nullptr", "NULL", "class",
        "public", "private", "protected", "virtual", "override", "template", "typename", "namespace", "using", "new",
        "delete", "this", "throw", "throws", "try", "catch", "finally", "final", "abstract", "interface", "extends",
        "implements", "import", "package", "fun", "val", "var", "when", "object", "is", "in", "super", "auto", "inline",
        "async", "await", "let", "func", "self", "nil", "YES", "NO", "id", "string", "function", "echo",
    ]
    private nonisolated static let python: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True",
        "False", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "pass", "break",
        "continue", "yield", "async", "await", "global", "nonlocal", "assert", "del", "self", "match", "case",
    ]
    private nonisolated static let ruby: Set<String> = [
        "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return",
        "yield", "begin", "rescue", "ensure", "raise", "nil", "true", "false", "self", "require", "then", "case", "when",
        "and", "or", "not", "attr_accessor", "attr_reader", "private", "puts",
    ]
    private nonisolated static let shell: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
        "return", "local", "export", "exit", "set", "unset", "source", "alias", "readonly", "declare", "shift", "trap",
    ]
    private nonisolated static let sql: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index",
        "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit",
        "offset", "as", "and", "or", "not", "null", "is", "in", "exists", "distinct", "union", "all", "primary", "key",
        "foreign", "references", "default", "with", "case", "when", "then", "else", "end", "asc", "desc", "view",
    ]

    // MARK: kept

    private final class Box { let text: AttributedString; init(_ text: AttributedString) { self.text = text } }
    private nonisolated(unsafe) static let kept: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    private nonisolated static func key(_ code: String, _ language: String) -> NSString { (language + "\u{0}" + code) as NSString }

    /// A block already colored, for drawing it again without waiting.
    nonisolated static func cached(_ code: String, language: String) -> AttributedString? {
        kept.object(forKey: key(code, language))?.text
    }

    /// Colors the code off the main actor and keeps it. Nil for a language this doesn't know.
    nonisolated static func highlight(_ code: String, language: String) async -> AttributedString? {
        if let hit = cached(code, language: language) { return hit }
        let text = await Task.detached(priority: .userInitiated) { attributed(code, language: language) }.value
        if let text { kept.setObject(Box(text), forKey: key(code, language), cost: code.utf8.count) }
        return text
    }
}
