import Foundation
import TetherProtocol

/// What differs from the last commit in a chat's directory, as the Changes pane shows it: the
/// daemon's `git/changes`, each file's lines numbered.
public struct WorkingChanges: Sendable, Equatable {
    public let branch: String?
    /// The repository's top directory, which the files' paths are relative to.
    public let root: String?
    public let files: [FileDiff]
    /// Summed once, not per draw.
    public let added: Int
    public let removed: Int
    /// New files past what the daemon reads, counted but not listed.
    public let omittedFiles: Int

    public init(branch: String?, root: String? = nil, files: [FileDiff], omittedFiles: Int = 0) {
        self.branch = branch
        self.root = root
        self.files = files
        added = files.reduce(0) { $0 + $1.added }
        removed = files.reduce(0) { $0 + $1.removed }
        self.omittedFiles = omittedFiles
    }

    /// The daemon's answer, numbered off the main actor: a file can be 5,000 lines, and hundreds of
    /// files change. Nil when the directory isn't in a repository.
    @concurrent
    public static func make(_ result: GitChangesResult) async -> WorkingChanges? {
        guard result.isRepo else { return nil }
        return WorkingChanges(branch: result.branch.flatMap(gitBranchName), root: result.root,
                              files: result.files.map(FileDiff.init), omittedFiles: result.omittedFiles)
    }
}

/// One file of the working tree's changes, its hunks' lines numbered for comments.
public struct FileDiff: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    /// The path it had before, for a rename.
    public let oldPath: String?
    public let hunks: [Hunk]
    public let isBinary: Bool
    /// Lines added and removed, lines left out included.
    public let added: Int
    public let removed: Int
    /// Lines past what the daemon keeps of a file, counted but not sent.
    public let omittedLines: Int
    /// The lines kept, across every hunk.
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    public struct Hunk: Sendable, Equatable, Identifiable {
        /// Its place in the file.
        public let id: Int
        /// "@@ -12,7 +12,9 @@ func body()", as git writes it.
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

    public init(_ file: WorkingFileChange) {
        path = file.path
        oldPath = file.oldPath
        isBinary = file.binary == true
        added = file.added
        removed = file.removed
        omittedLines = file.truncatedLines
        hunks = file.hunks.enumerated().map { id, hunk in
            var old = hunk.oldStart, new = hunk.newStart
            var lines: [Line] = []
            lines.reserveCapacity(hunk.lines.count)
            for line in hunk.diffLines {
                switch line.kind {
                case .added:
                    lines.append(Line(kind: .added, text: line.text, oldNumber: nil, newNumber: new))
                    new += 1
                case .removed:
                    lines.append(Line(kind: .removed, text: line.text, oldNumber: old, newNumber: nil))
                    old += 1
                case .context:
                    lines.append(Line(kind: .context, text: line.text, oldNumber: old, newNumber: new))
                    old += 1
                    new += 1
                }
            }
            let header = "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
                + (hunk.header.map { " " + $0 } ?? "")
            return Hunk(id: id, header: header, lines: lines)
        }
    }
}

/// The branch from the header of `git status -b`, which the daemon passes on as git wrote it:
/// "main", "No commits yet on main" in a new repository, and "HEAD (no branch)" when detached,
/// which has no branch to name.
func gitBranchName(_ branch: String) -> String? {
    guard !branch.isEmpty, branch != "HEAD (no branch)" else { return nil }
    for prefix in ["No commits yet on ", "Initial commit on "] where branch.hasPrefix(prefix) {
        return String(branch.dropFirst(prefix.count))
    }
    return branch
}
