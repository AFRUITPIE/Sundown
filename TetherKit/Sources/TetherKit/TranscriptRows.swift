import TetherProtocol

/// One row in the rendered transcript: either a single item, or a run of consecutive,
/// unremarkable finished tool calls collapsed into one quiet summary line.
public enum TranscriptRow: Sendable {
    case item(Item)
    case toolGroup([Item.ToolCall])

    public var id: String {
        switch self {
        case .item(let item): return item.id
        // Keyed on the first call's id: stable as long as the group's contents don't reorder,
        // which they don't — items only ever append or mutate in place.
        case .toolGroup(let calls): return "group-\(calls.first?.id ?? "")"
        }
    }
}

/// Folds top-level items into display rows, collapsing consecutive finished tool calls into a
/// single "Used N tools" row. A call breaks the run — and stays on its own line — while it's
/// still doing something worth watching, or while it needs attention:
///   - not yet `.completed` (pending/running/failed/denied/interrupted)
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

private func isGroupable(_ call: Item.ToolCall) -> Bool {
    call.status == .completed && call.kind != .todoWrite && call.kind != .subagent
}

// MARK: find

extension TranscriptRow {
    /// What Find in Chat matches against: what the row shows or holds — a message's text, a tool
    /// call's input values and output — as one string.
    public var searchText: String {
        switch self {
        case .item(let item): return item.searchText
        case .toolGroup(let calls): return calls.map { Item.toolCall($0).searchText }.joined(separator: "\n")
        }
    }

    /// Whether the row matches `query`, case- and diacritic-insensitively.
    public func matches(_ query: String) -> Bool {
        !query.isEmpty && searchText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
