import Foundation

/// `git diff` output, parsed into files, hunks and numbered lines for the Changes pane.
public struct FileDiff: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    /// The path it had before, for a rename.
    public let oldPath: String?
    public let hunks: [Hunk]
    public let isBinary: Bool
    public var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    public init(path: String, oldPath: String? = nil, hunks: [Hunk], isBinary: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.hunks = hunks
        self.isBinary = isBinary
    }

    public struct Hunk: Sendable, Equatable, Identifiable {
        public var id: String { header }
        /// "@@ -12,7 +12,9 @@ func body()", as git wrote it.
        public let header: String
        public let lines: [Line]
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
        let numbered = lines.enumerated().map { Line(kind: .added, text: $1, oldNumber: nil, newNumber: $0 + 1) }
        return FileDiff(path: path, hunks: [Hunk(header: "@@ -0,0 +1,\(numbered.count) @@", lines: numbered)])
    }
}

public enum UnifiedDiff {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var path: String?
        var oldPath: String?
        var isBinary = false
        var hunks: [FileDiff.Hunk] = []
        var header: String?
        var lines: [FileDiff.Line] = []
        var oldLine = 0, newLine = 0

        func closeHunk() {
            if let header { hunks.append(.init(header: header, lines: lines)) }
            header = nil
            lines = []
        }
        func closeFile() {
            closeHunk()
            if let path { files.append(FileDiff(path: path, oldPath: oldPath == path ? nil : oldPath, hunks: hunks, isBinary: isBinary)) }
            path = nil; oldPath = nil; isBinary = false; hunks = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
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
                header = line
                // "@@ -a,b +c,d @@"
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
            } else if header != nil {
                if line.hasPrefix("+") {
                    lines.append(.init(kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine))
                    newLine += 1
                } else if line.hasPrefix("-") {
                    lines.append(.init(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil))
                    oldLine += 1
                } else if line.hasPrefix(" ") {
                    lines.append(.init(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1
                }
                // "\ No newline at end of file" and the empty last line: nothing to show.
            }
        }
        closeFile()
        return files
    }
}
