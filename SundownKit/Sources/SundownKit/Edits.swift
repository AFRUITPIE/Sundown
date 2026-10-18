import TetherProtocol

/// Two versions of some text compared line by line, for an edit the daemon hasn't diffed: one a
/// permission request asks about, or a call still running. A finished call's change is its `edit`.
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
}

extension DiffHunk {
    /// Each line's kind and text, as the daemon writes them (`' '`, `'+'` or `'-'` before the
    /// text); "No newline at end of file" (`'\'`) says nothing to show.
    public var diffLines: [LineDiff.Line] {
        lines.compactMap { line in
            switch line.first {
            case "+": LineDiff.Line(.added, String(line.dropFirst()))
            case "-": LineDiff.Line(.removed, String(line.dropFirst()))
            case "\\": nil
            default: LineDiff.Line(.context, String(line.dropFirst()))
            }
        }
    }
}

/// What a finished turn's edits changed, file by file, from its calls' own edits (`edit`) rather
/// than the working tree: after the turn, the files may have changed again.
public struct EditedFiles: Sendable, Hashable {
    public struct File: Sendable, Hashable, Identifiable {
        public let path: String
        /// In the order they were made.
        public let edits: [FileEdit]
        public let added: Int
        public let removed: Int
        public var id: String { path }

        public init(path: String, edits: [FileEdit]) {
            self.path = path
            self.edits = edits
            added = edits.reduce(0) { $0 + $1.added }
            removed = edits.reduce(0) { $0 + $1.removed }
        }
    }

    /// The prompt the turn answered. Restore Files… puts the files back to before it.
    public let promptID: String
    /// In the order each was first changed.
    public let files: [File]
    /// Lines added and removed: the turn's own totals when the daemon has said them (a background
    /// agent's later edit included), else the files' summed.
    public let added: Int
    public let removed: Int

    public init(promptID: String, files: [File], totals: TurnEdits? = nil) {
        self.promptID = promptID
        self.files = files
        added = totals?.added ?? files.reduce(0) { $0 + $1.added }
        removed = totals?.removed ?? files.reduce(0) { $0 + $1.removed }
    }

    /// The edits among one turn's items — a subagent's included, since they changed the files too —
    /// or nil when it changed none.
    public static func summarize(promptID: String, _ items: some Sequence<Item>, totals: TurnEdits? = nil) -> EditedFiles? {
        var order: [String] = []
        var byPath: [String: [FileEdit]] = [:]
        for case .toolCall(let call) in items {
            guard let edit = call.edit else { continue }
            if byPath[edit.path] == nil { order.append(edit.path) }
            byPath[edit.path, default: []].append(edit)
        }
        guard !order.isEmpty else { return nil }
        return EditedFiles(promptID: promptID, files: order.map { File(path: $0, edits: byPath[$0]!) }, totals: totals)
    }
}

/// Each finished turn's edits, by the id of the prompt that started it. A turn runs from a prompt
/// of the chat's own (not a subagent's) to the next; the items before the first prompt held — the
/// end of a turn whose prompt is on an older page — and a running last turn have none. `totals`:
/// each turn's own totals by its id (`Turn.edits`).
public func editedFiles(in items: [Item], lastTurnRunning: Bool, totals: [String: TurnEdits] = [:]) -> [String: EditedFiles] {
    var starts: [(prompt: Item.UserMessage, index: Int)] = []
    for (i, item) in items.enumerated() {
        if case .userMessage(let m) = item, m.parentToolUseId == nil { starts.append((m, i)) }
    }
    var out: [String: EditedFiles] = [:]
    for (n, start) in starts.enumerated() {
        let isLast = n == starts.count - 1
        if isLast, lastTurnRunning { break }
        let end = isLast ? items.endIndex : starts[n + 1].index
        if let edits = EditedFiles.summarize(promptID: start.prompt.id, items[(start.index + 1)..<end],
                                             totals: start.prompt.turnId.flatMap { totals[$0] }) {
            out[start.prompt.id] = edits
        }
    }
    return out
}

extension FileEdit {
    /// What a finished Edit, MultiEdit, Write or NotebookEdit call changed, compared from its own
    /// input as the daemon does when Claude Code reports no patch: one hunk per edit, its place in
    /// the file unknown. For samples and the UI tests' fixture, whose calls have no daemon to diff
    /// them. Nil for a call that changed nothing or isn't an edit.
    public static func comparingInput(of call: Item.ToolCall) -> FileEdit? {
        guard call.status == .completed, call.isError != true else { return nil }
        let input = call.input
        let path: String?
        var pairs: [(old: String, new: String)]
        switch call.kind {
        case .fileEdit:
            path = input["file_path"]?.stringValue
            if let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
                pairs = [(old, new)]
            } else {
                pairs = (input["edits"]?.arrayValue ?? []).map { ($0["old_string"]?.stringValue ?? "", $0["new_string"]?.stringValue ?? "") }
            }
        case .fileWrite:
            path = input["file_path"]?.stringValue
            pairs = [("", input["content"]?.stringValue ?? "")]
        case .notebookEdit:
            path = input["notebook_path"]?.stringValue
            pairs = input["edit_mode"]?.stringValue == "delete" ? [] : [("", input["new_source"]?.stringValue ?? "")]
        default:
            return nil
        }
        guard let path else { return nil }
        let hunks = pairs.map { pair in
            let lines = LineDiff.lines(old: pair.old, new: pair.new)
            return DiffHunk(oldStart: 0, oldLines: lines.count { $0.kind != .added }, newStart: 0,
                            newLines: lines.count { $0.kind != .removed },
                            lines: lines.map { line in
                                switch line.kind {
                                case .added: "+" + line.text
                                case .removed: "-" + line.text
                                case .context: " " + line.text
                                }
                            })
        }
        let all = hunks.flatMap(\.lines)
        return FileEdit(path: path, hunks: hunks, added: all.count { $0.hasPrefix("+") }, removed: all.count { $0.hasPrefix("-") })
    }
}

extension Item.ToolCall {
    /// The call with its `edit` filled in from its input, as the daemon would send it.
    public var withComparedEdit: Item.ToolCall {
        var call = self
        if call.edit == nil { call.edit = FileEdit.comparingInput(of: call) }
        return call
    }
}
