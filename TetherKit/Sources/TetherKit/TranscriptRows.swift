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
public func foldTranscriptRows(_ items: [Item]) -> [TranscriptRow] {
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
        if case .toolCall(let call) = item, isGroupable(call) {
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
