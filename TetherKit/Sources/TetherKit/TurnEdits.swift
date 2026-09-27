import TetherProtocol

/// Two versions of some text compared line by line, as the transcript shows an edit. Pure, so the
/// edited-files row's counts and the diff it opens come from the same comparison.
public enum LineDiff {
    public struct Line: Hashable, Sendable {
        public enum Kind: Sendable { case context, added, removed }
        public let kind: Kind
        public let text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// The text's lines. Empty text has none, and a final newline doesn't start another.
    public static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Every line of both, in order: each removal just before what replaced it.
    public static func lines(old: String, new: String) -> [Line] {
        let a = split(old), b = split(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append(Line(.removed, a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append(Line(.added, b[j])); j += 1
            } else {
                if j < b.count { out.append(Line(.context, b[j])) }
                i += 1; j += 1
            }
        }
        return out
    }

    /// How many lines `new` adds and removes compared with `old`.
    public static func counts(old: String, new: String) -> (added: Int, removed: Int) {
        let a = split(old), b = split(new)
        if a.isEmpty || b.isEmpty { return (b.count, a.count) }
        let diff = b.difference(from: a)
        return (diff.insertions.count, diff.removals.count)
    }
}

/// One change a tool call made to a file, from its input: an Edit's old and new text (each of a
/// MultiEdit's), a Write's content, or a NotebookEdit's new cell source. A Write or a notebook cell
/// doesn't carry what was there before, so its old text is empty and all of it counts as added.
public struct FileChange: Sendable, Hashable {
    public let path: String
    public let old: String
    public let new: String
    public let added: Int
    public let removed: Int

    public init(path: String, old: String, new: String) {
        self.path = path
        self.old = old
        self.new = new
        (added, removed) = LineDiff.counts(old: old, new: new)
    }

    /// What a finished call changed; nothing for a call that failed, was denied or stopped, or
    /// isn't an edit.
    public static func changes(of call: Item.ToolCall) -> [FileChange] {
        guard call.status == .completed, call.isError != true else { return [] }
        let input = call.input
        switch call.kind {
        case .fileEdit:
            guard let path = input["file_path"]?.stringValue else { return [] }
            if let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
                return [FileChange(path: path, old: old, new: new)]
            }
            return (input["edits"]?.arrayValue ?? []).map {
                FileChange(path: path, old: $0["old_string"]?.stringValue ?? "", new: $0["new_string"]?.stringValue ?? "")
            }
        case .fileWrite:
            guard let path = input["file_path"]?.stringValue else { return [] }
            return [FileChange(path: path, old: "", new: input["content"]?.stringValue ?? "")]
        case .notebookEdit:
            guard let path = input["notebook_path"]?.stringValue else { return [] }
            // Deleting a cell carries none of what it held.
            if input["edit_mode"]?.stringValue == "delete" { return [] }
            return [FileChange(path: path, old: "", new: input["new_source"]?.stringValue ?? "")]
        default:
            return []
        }
    }
}

/// What a finished turn's edits changed, file by file, from the calls' own inputs rather than the
/// working tree: after the turn, the files may have changed again.
public struct TurnEdits: Sendable, Hashable {
    public struct File: Sendable, Hashable, Identifiable {
        public let path: String
        /// In the order they were made.
        public let changes: [FileChange]
        public let added: Int
        public let removed: Int
        public var id: String { path }

        public init(path: String, changes: [FileChange]) {
            self.path = path
            self.changes = changes
            added = changes.reduce(0) { $0 + $1.added }
            removed = changes.reduce(0) { $0 + $1.removed }
        }
    }

    /// The prompt the turn answered. Restore Files… puts the files back to before it.
    public let promptID: String
    /// In the order each was first changed.
    public let files: [File]
    public let added: Int
    public let removed: Int

    public init(promptID: String, files: [File]) {
        self.promptID = promptID
        self.files = files
        added = files.reduce(0) { $0 + $1.added }
        removed = files.reduce(0) { $0 + $1.removed }
    }

    /// The edits among one turn's items — a subagent's included, since they changed the files too —
    /// or nil when it changed none.
    public static func summarize(promptID: String, _ items: some Sequence<Item>,
                                 changes: (Item.ToolCall) -> [FileChange] = FileChange.changes(of:)) -> TurnEdits? {
        var order: [String] = []
        var byPath: [String: [FileChange]] = [:]
        for case .toolCall(let call) in items {
            for change in changes(call) {
                if byPath[change.path] == nil { order.append(change.path) }
                byPath[change.path, default: []].append(change)
            }
        }
        guard !order.isEmpty else { return nil }
        return TurnEdits(promptID: promptID, files: order.map { File(path: $0, changes: byPath[$0]!) })
    }
}

/// Each finished turn's edits, by the id of the prompt that started it. A turn runs from a prompt
/// of the chat's own (not a subagent's) to the next; the items before the first prompt held — the
/// end of a turn whose prompt is on an older page — and a running last turn have none.
public func turnEdits(in items: [Item], lastTurnRunning: Bool,
                      changes: (Item.ToolCall) -> [FileChange] = FileChange.changes(of:)) -> [String: TurnEdits] {
    var starts: [(promptID: String, index: Int)] = []
    for (i, item) in items.enumerated() {
        if case .userMessage(let m) = item, m.parentToolUseId == nil { starts.append((m.id, i)) }
    }
    var out: [String: TurnEdits] = [:]
    for (n, start) in starts.enumerated() {
        let isLast = n == starts.count - 1
        if isLast, lastTurnRunning { break }
        let end = isLast ? items.endIndex : starts[n + 1].index
        if let edits = TurnEdits.summarize(promptID: start.promptID, items[(start.index + 1)..<end], changes: changes) {
            out[start.promptID] = edits
        }
    }
    return out
}
