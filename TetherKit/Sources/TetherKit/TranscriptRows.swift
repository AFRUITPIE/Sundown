import Foundation
import TetherProtocol

/// One row in the rendered transcript: a single item, a run of consecutive finished tool calls
/// collapsed into one quiet summary line, a finished turn's work folded behind its last reply, the
/// files a finished turn edited, or the date above a prompt.
public indirect enum TranscriptRow: Sendable, Equatable {
    case item(Item)
    case toolGroup([Item.ToolCall])
    /// Everything a finished turn did before its last message, as one "Worked for" line
    /// (Settings ▸ Advanced ▸ Tool Calls ▸ Worked For). `durationMs` runs from the prompt to that
    /// message, when both are known.
    case turnWork(id: String, rows: [TranscriptRow], durationMs: Double?)
    /// The files a finished turn edited, after its last row.
    case turnEdits(TurnEdits)
    /// When a prompt was sent, above it, where the chat picks up after a break (`DateSeparators`).
    case dateSeparator(promptID: String, ms: Double)

    public var id: String {
        switch self {
        case .item(let item): return item.id
        // Keyed on the first call's id: stable as long as the group's contents don't reorder,
        // which they don't — items only ever append or mutate in place.
        case .toolGroup(let calls): return "group-\(calls.first?.id ?? "")"
        case .turnWork(let id, _, _): return id
        case .turnEdits(let edits): return "edits-\(edits.promptID)"
        case .dateSeparator(let promptID, _): return "date-\(promptID)"
        }
    }
}

/// How finished tool calls fold, per Settings ▸ Advanced ▸ Tool Calls.
public enum TranscriptFolding: Sendable, Hashable {
    /// Each run of finished calls on one line.
    case summarized
    /// One line per call.
    case everyCall
    /// A finished turn's work before its last message on one line; the running turn as `summarized`.
    case workedFor
}

/// Folds top-level items into display rows, collapsing consecutive finished tool calls into a
/// single summary row, calls that failed, were denied or stopped included: an agent's missteps are
/// ordinary, so the run only says how many failed, quietly. A call breaks the run — and stays on
/// its own line — while it's still doing something worth watching, or when it's more than a line:
///   - still running (`.pending`/`.running`)
///   - `.todoWrite`, whose checklist is always shown inline and shouldn't be folded away
///   - `.subagent`, whose nested transcript is a heavier construct than a plain tool line
/// A single ungroupable-adjacent completed call is left as a plain `.item`, not a one-call group.
///
/// Reasoning items are dropped here rather than rendered: the model's internal monologue competes
/// with its actual answer. `ThreadModel` still keeps them, and `ThreadModel.isThinking` drives the
/// one line that marks the wait before a reply starts.
public func foldTranscriptRows(_ items: [Item], grouping: Bool = true) -> [TranscriptRow] {
    var rows: [TranscriptRow] = []
    var run: [Item.ToolCall] = []

    func flushRun() {
        switch run.count {
        case 0: break
        case 1: rows.append(.item(.toolCall(run[0])))
        default: rows.append(.toolGroup(run))
        }
        run.removeAll()
    }

    for item in items {
        if case .reasoning = item {
            continue
        } else if grouping, case .toolCall(let call) = item, isGroupable(call) {
            run.append(call)
        } else {
            flushRun()
            rows.append(.item(item))
        }
    }
    flushRun()
    return rows
}

/// Folds items as `folding` says. With `.workedFor`, each finished turn — every turn but a running
/// last one — keeps its prompt and its last message, and folds what came between into one
/// `.turnWork` row when that includes a tool call. A turn with no message after its work shows as
/// it would with `.summarized`, since nothing would be left to read.
public func foldTranscriptRows(_ items: [Item], folding: TranscriptFolding, lastTurnRunning: Bool) -> [TranscriptRow] {
    switch folding {
    case .summarized: return foldTranscriptRows(items)
    case .everyCall: return foldTranscriptRows(items, grouping: false)
    case .workedFor: break
    }
    // Turns, each from a prompt (or the start) up to the next prompt.
    var turns: [ArraySlice<Item>] = []
    var start = items.startIndex
    for (i, item) in items.enumerated() where i > start {
        if case .userMessage = item {
            turns.append(items[start..<i])
            start = i
        }
    }
    if start < items.endIndex { turns.append(items[start...]) }

    var rows: [TranscriptRow] = []
    for (t, turn) in turns.enumerated() {
        let isRunning = lastTurnRunning && t == turns.count - 1
        guard !isRunning,
              case .userMessage(let prompt)? = turn.first,
              let last = turn.lastIndex(where: { if case .agentMessage = $0 { true } else { false } }) else {
            rows += foldTranscriptRows(Array(turn))
            continue
        }
        let work = turn[turn.index(after: turn.startIndex)..<last]
        guard work.contains(where: { if case .toolCall = $0 { true } else { false } }) else {
            rows += foldTranscriptRows(Array(turn))
            continue
        }
        rows.append(.item(.userMessage(prompt)))
        let end = turn[last].createdAt
        rows.append(.turnWork(id: "work-\(prompt.id)", rows: foldTranscriptRows(Array(work)),
                              durationMs: end > 0 && prompt.createdAt > 0 ? end - prompt.createdAt : nil))
        rows += foldTranscriptRows(Array(turn[last...]))
    }
    return rows
}

private func isGroupable(_ call: Item.ToolCall) -> Bool {
    call.status != .running && call.status != .pending && call.kind != .todoWrite && call.kind != .subagent
}

/// Folded rows with what goes between turns: a date above each prompt in `dates` (by prompt id,
/// from `DateSeparators.prompts`), and each turn's edits in `edits` (from `turnEdits`) after the
/// turn's last row, before the next prompt's date.
public func decorateTranscriptRows(_ rows: [TranscriptRow], dates: [String: Double], edits: [String: TurnEdits]) -> [TranscriptRow] {
    guard !dates.isEmpty || !edits.isEmpty else { return rows }
    var out: [TranscriptRow] = []
    out.reserveCapacity(rows.count + dates.count + edits.count)
    var turn: String?
    func endTurn() {
        if let turn, let e = edits[turn] { out.append(.turnEdits(e)) }
    }
    for row in rows {
        if case .item(.userMessage(let m)) = row, m.parentToolUseId == nil {
            endTurn()
            if let ms = dates[m.id] { out.append(.dateSeparator(promptID: m.id, ms: ms)) }
            turn = m.id
        }
        out.append(row)
    }
    endTurn()
    return out
}

/// Where the transcript marks the time, as Messages does: above a prompt that follows a break.
public enum DateSeparators {
    /// A break is longer than this since the last thing in the chat.
    public static let gap: Double = 60 * 60 * 1000

    /// Whether a prompt sent at `time` (ms since 1970) gets the date above it: the first prompt
    /// shown, a prompt on a different day from the one before it, or one sent more than an hour
    /// after whatever came before it.
    public static func needsSeparator(at time: Double, previousPrompt: Double?, previousItem: Double?,
                                      calendar: Calendar = .current) -> Bool {
        guard let previousPrompt else { return true }
        let date = Date(timeIntervalSince1970: time / 1000)
        if !calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: previousPrompt / 1000)) { return true }
        return time - (previousItem ?? previousPrompt) > gap
    }

    /// The prompts among the chat's top-level items that get a date above them, with when each
    /// was sent. An item with no time (0) neither gets one nor counts as what came before.
    public static func prompts(in items: [Item], calendar: Calendar = .current) -> [String: Double] {
        var out: [String: Double] = [:]
        var previousPrompt: Double?
        var previousItem: Double?
        for item in items where item.parentToolUseId == nil {
            let time = item.createdAt
            guard time > 0 else { continue }
            if case .userMessage(let m) = item {
                if needsSeparator(at: time, previousPrompt: previousPrompt, previousItem: previousItem, calendar: calendar) {
                    out[m.id] = time
                }
                previousPrompt = time
            }
            previousItem = max(previousItem ?? 0, time)
        }
        return out
    }
}

/// Chat ▸ Previous Prompt and Next Prompt: which row to bring to the top of the transcript.
public enum PromptNavigation {
    public enum Direction: Sendable { case previous, next }

    /// The rows the reader's own prompts are reached by: each prompt, or the date above it when it
    /// has one, so the date comes into view too. In transcript order.
    public static func targets(in rows: [TranscriptRow]) -> [(index: Int, id: String)] {
        var out: [(index: Int, id: String)] = []
        for (i, row) in rows.enumerated() {
            guard case .item(.userMessage(let m)) = row, m.parentToolUseId == nil, m.synthetic != true else { continue }
            if i > 0, case .dateSeparator(let promptID, _) = rows[i - 1], promptID == m.id {
                out.append((i - 1, rows[i - 1].id))
            } else {
                out.append((i, row.id))
            }
        }
        return out
    }

    /// The prompt before or after where the reader is: `lastTarget`, the prompt last gone to, until
    /// the reader scrolls for themselves (the caller forgets it then), otherwise the topmost row on
    /// screen. Not whether it's on screen yet: pressed again quickly, the scroll to it hasn't landed,
    /// and each press went back to the same prompt. A date gone to can go when an older page puts
    /// the prompt before it on the same day; its prompt stands in. With nothing on screen, Previous
    /// goes to the last prompt. Nil when there's none that way.
    public static func target(_ direction: Direction, rows: [TranscriptRow], visible: Set<String>,
                              lastTarget: String? = nil) -> String? {
        let targets = targets(in: rows)
        let anchor: Int? = if let lastTarget,
                              let i = rows.firstIndex(where: { $0.id == lastTarget })
                                  ?? rows.firstIndex(where: { TranscriptRow.dateSeparator(promptID: $0.id, ms: 0).id == lastTarget }) {
            i
        } else {
            rows.firstIndex { visible.contains($0.id) }
        }
        switch direction {
        case .previous:
            guard let anchor else { return targets.last?.id }
            return targets.last { $0.index < anchor }?.id
        case .next:
            guard let anchor else { return nil }
            return targets.first { $0.index > anchor }?.id
        }
    }
}

// MARK: find

extension TranscriptRow {
    /// What Find in Chat matches against: what the row shows or holds — a message's text, a tool
    /// call's input values and output — as one string.
    public var searchText: String {
        switch self {
        case .item(let item): return item.searchText
        case .toolGroup(let calls): return calls.map { Item.toolCall($0).searchText }.joined(separator: "\n")
        case .turnWork(_, let rows, _): return rows.map(\.searchText).joined(separator: "\n")
        // Their files are in the calls, which match already.
        case .turnEdits, .dateSeparator: return ""
        }
    }

    /// Whether the row matches `query`, case- and diacritic-insensitively.
    public func matches(_ query: String) -> Bool {
        !query.isEmpty && Self.text(searchText, matches: query)
    }

    /// Whether `text`, a row's `searchText`, holds `query` as `matches` compares them, for a caller
    /// that keeps rows' search text rather than making it again for every query.
    public static func text(_ text: String, matches query: String) -> Bool {
        !query.isEmpty && text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

extension Item {
    var searchText: String {
        switch self {
        case .userMessage(let m):
            return m.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined(separator: "\n")
        case .agentMessage(let m): return m.text
        case .toolCall(let t): return ([t.name] + t.input.strings + [t.outputText ?? ""]).joined(separator: "\n")
        case .error(let e): return e.message
        case .notice(let n): return n.text
        default: return ""
        }
    }
}

private extension JSONValue {
    /// Every string in the value, depth first.
    var strings: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap(\.strings)
        case .object(let o): return o.keys.sorted().flatMap { o[$0]!.strings }
        default: return []
        }
    }
}
