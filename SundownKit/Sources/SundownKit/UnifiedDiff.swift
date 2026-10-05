import Foundation

/// `git diff` output, parsed into files, hunks and numbered lines for the Changes pane.
public struct FileDiff: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    /// The path it had before, for a rename.
    public let oldPath: String?
    /// Each hunk's `id` is its place in the file, so a staged and an unstaged hunk with the same
    /// header are still two hunks.
    public let hunks: [Hunk]
    public let isBinary: Bool
    /// Lines added and removed, counted once when parsed, lines left out included.
    public let added: Int
    public let removed: Int
    /// Lines past `UnifiedDiff.maxLinesPerFile` that were counted but not kept.
    public let omittedLines: Int
    /// The lines kept, across every hunk.
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    public init(path: String, oldPath: String? = nil, hunks: [Hunk], isBinary: Bool = false) {
        let lines = hunks.lazy.flatMap(\.lines)
        self.init(path: path, oldPath: oldPath, hunks: hunks, isBinary: isBinary,
                  added: lines.count { $0.kind == .added }, removed: lines.count { $0.kind == .removed }, omittedLines: 0)
    }

    init(path: String, oldPath: String?, hunks: [Hunk], isBinary: Bool, added: Int, removed: Int, omittedLines: Int) {
        self.path = path
        self.oldPath = oldPath
        self.hunks = hunks.enumerated().map { Hunk(id: $0, header: $1.header, lines: $1.lines) }
        self.isBinary = isBinary
        self.added = added
        self.removed = removed
        self.omittedLines = omittedLines
    }

    /// This file's changes followed by `other`'s, for a file with both staged and unstaged edits.
    public func followed(by other: FileDiff) -> FileDiff {
        FileDiff(path: path, oldPath: oldPath ?? other.oldPath, hunks: hunks + other.hunks, isBinary: isBinary || other.isBinary,
                 added: added + other.added, removed: removed + other.removed, omittedLines: omittedLines + other.omittedLines)
    }

    public struct Hunk: Sendable, Equatable, Identifiable {
        /// Its place in the file.
        public let id: Int
        /// "@@ -12,7 +12,9 @@ func body()", as git wrote it.
        public let header: String
        public let lines: [Line]

        public init(id: Int = 0, header: String, lines: [Line]) {
            self.id = id
            self.header = header
            self.lines = lines
        }
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable { case context, added, removed }
        public let kind: Kind
        public let text: String
        /// Its number in the old and new file; nil on the side it isn't on.
        public let oldNumber: Int?
        public let newNumber: Int?
        public var id: String { "\(oldNumber ?? -1):\(newNumber ?? -1):\(kind)" }
    }

    /// A new file's whole content as one added hunk, for an untracked file git has no diff of.
    public static func added(path: String, content: String) -> FileDiff {
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let kept = lines.prefix(UnifiedDiff.maxLinesPerFile)
        let numbered = kept.enumerated().map {
            Line(kind: .added, text: UnifiedDiff.clipped($1), oldNumber: nil, newNumber: $0 + 1)
        }
        return FileDiff(path: path, oldPath: nil, hunks: [Hunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: numbered)],
                        isBinary: false, added: lines.count, removed: 0, omittedLines: lines.count - kept.count)
    }
}

public enum UnifiedDiff {
    /// Lines kept per file. Past it they're counted, not kept: a generated file or a lockfile can
    /// be hundreds of thousands of lines, which no one reads in the inspector.
    public static let maxLinesPerFile = 5_000
    /// Characters kept per line; a minified file is one line of megabytes.
    public static let maxLineLength = 1_000

    static func clipped(_ text: some StringProtocol) -> String {
        text.count > maxLineLength ? String(text.prefix(maxLineLength)) + "…" : String(text)
    }

    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var path: String?
        var oldPath: String?
        var isBinary = false
        var hunks: [FileDiff.Hunk] = []
        var header: String?
        var lines: [FileDiff.Line] = []
        var oldLine = 0, newLine = 0
        var kept = 0, added = 0, removed = 0, omitted = 0

        func closeHunk() {
            if let header { hunks.append(.init(header: header, lines: lines)) }
            header = nil
            lines = []
        }
        func closeFile() {
            closeHunk()
            if let path {
                files.append(FileDiff(path: path, oldPath: oldPath == path ? nil : oldPath, hunks: hunks, isBinary: isBinary,
                                      added: added, removed: removed, omittedLines: omitted))
            }
            path = nil; oldPath = nil; isBinary = false; hunks = []
            kept = 0; added = 0; removed = 0; omitted = 0
        }
        func append(_ kind: FileDiff.Line.Kind, _ raw: Substring, old: Int?, new: Int?) {
            if kind == .added { added += 1 } else if kind == .removed { removed += 1 }
            guard kept < maxLinesPerFile else { omitted += 1; return }
            kept += 1
            lines.append(.init(kind: kind, text: clipped(raw.dropFirst()), oldNumber: old, newNumber: new))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                // "diff --git a/x b/y": the b side until +++ says otherwise.
                if let range = line.range(of: " b/", options: .backwards) {
                    path = String(line[range.upperBound...])
                    let a = line.dropFirst("diff --git a/".count)
                    oldPath = a.range(of: " b/").map { String(a[..<$0.lowerBound]) }
                }
            } else if header == nil, line.hasPrefix("+++ ") {
                let p = line.dropFirst(4)
                if p != "/dev/null" { path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : String(p) }
            } else if header == nil, line.hasPrefix("--- ") {
                continue
            } else if line.hasPrefix("Binary files ") {
                isBinary = true
            } else if line.hasPrefix("@@") {
                closeHunk()
                header = String(line)
                // "@@ -a,b +c,d @@"
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
            } else if header != nil {
                if line.hasPrefix("+") {
                    append(.added, line, old: nil, new: newLine)
                    newLine += 1
                } else if line.hasPrefix("-") {
                    append(.removed, line, old: oldLine, new: nil)
                    oldLine += 1
                } else if line.hasPrefix(" ") {
                    append(.context, line, old: oldLine, new: newLine)
                    oldLine += 1; newLine += 1
                }
                // "\ No newline at end of file" and the empty last line: nothing to show.
            }
        }
        closeFile()
        return files
    }

    /// The working tree's files: the staged diff, then the unstaged one (a file with both shows
    /// both, one after the other), then untracked files' contents (nil for one that isn't text),
    /// sorted by path. Parsed off the main actor: a diff can be megabytes.
    @concurrent
    public static func workingTree(staged: String, unstaged: String, untracked: [(path: String, content: String?)]) async -> [FileDiff] {
        var files = parse(staged)
        var index = Dictionary(files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        for file in parse(unstaged) {
            if let i = index[file.path] {
                files[i] = files[i].followed(by: file)
            } else {
                index[file.path] = files.count
                files.append(file)
            }
        }
        for (path, content) in untracked {
            files.append(content.map { .added(path: path, content: $0) } ?? FileDiff(path: path, hunks: [], isBinary: true))
        }
        return files.sorted { $0.path < $1.path }
    }
}
