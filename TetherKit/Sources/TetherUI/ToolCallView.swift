import SwiftUI
import TetherKit
import TetherProtocol

/// One quiet transcript line for a tool call: a small icon, a plain-text description, and a
/// disclosure chevron that expands to the same kind-specific detail as always — no fill, no
/// border, no bold title. Color only shows up when the call needs attention (failed, denied,
/// or still running); a finished call is just secondary/tertiary text, same as everything else
/// in the transcript that isn't asking for a reaction.
struct ToolCallView: View {
    let call: Item.ToolCall
    let thread: ThreadModel
    @State private var expanded = false

    private var input: JSONValue { call.input }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded || alwaysShowBody {
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.fill.quinary, in: .rect(cornerRadius: 8))
                    .padding(.top, 6)
                    .padding(.leading, 24)
            }
        }
    }

    private var alwaysShowBody: Bool {
        call.kind == .todoWrite || (call.kind == .subagent && call.status == .running)
    }

    private var accentColor: Color {
        switch call.status {
        case .failed: return .red
        case .denied: return .orange
        case .running, .pending: return .blue
        default: return .secondary
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(accentColor).frame(width: 16)
            Text(title).foregroundStyle(.secondary)
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let s = call.elapsedSeconds, call.status == .running {
                Text(Format.duration(s)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            statusGlyph
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .font(.callout)
    }

    /// Nothing for a completed call (no checkmark shouting at you) — a glyph appears only when
    /// there's something to notice.
    @ViewBuilder private var statusGlyph: some View {
        switch call.status {
        case .pending, .running: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.caption)
        case .interrupted: Image(systemName: "stop.fill").foregroundStyle(.tertiary).font(.caption2)
        default: EmptyView()
        }
    }

    private var symbol: String {
        switch call.kind {
        case .bash: return "terminal"
        case .fileRead: return "doc.text"
        case .fileWrite: return "doc.badge.plus"
        case .fileEdit, .notebookEdit: return "pencil"
        case .grep, .glob: return "magnifyingglass"
        case .webFetch: return "globe"
        case .webSearch: return "safari"
        case .mcp: return "puzzlepiece.extension"
        case .subagent: return "person.2"
        case .todoWrite, .task: return "checklist"
        case .askUserQuestion: return "questionmark.bubble"
        case .exitPlanMode, .enterPlanMode: return "list.bullet.clipboard"
        case .skill: return "sparkles"
        case .monitor: return "waveform.path.ecg"
        case .schedule: return "clock"
        case .worktree: return "arrow.triangle.branch"
        default: return "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch call.kind {
        case .bash: return "Ran a command"
        case .fileRead: return "Read"
        case .fileWrite: return "Write"
        case .fileEdit: return "Edit"
        case .grep, .glob: return "Searched for"
        case .webSearch: return "Searched the web for"
        case .subagent: return input.string("subagent_type").map { "Agent · \($0)" } ?? "Agent"
        case .mcp:
            let parts = call.name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.count >= 3 ? "\(parts[1]) · \(parts[2...].joined(separator: "_"))" : call.name
        case .todoWrite: return "Todos"
        default: return call.name
        }
    }

    private var subtitle: String {
        if let s = call.summary { return s }
        switch call.kind {
        case .bash: return input.string("description") ?? input.string("command") ?? ""
        case .fileRead, .fileWrite, .fileEdit, .notebookEdit:
            return (input.string("file_path") ?? input.string("notebook_path") ?? "").abbreviatingHome
        case .grep, .glob: return input.string("pattern").map { "\"\($0)\"" } ?? ""
        case .webFetch: return input.string("url") ?? ""
        case .webSearch: return input.string("query").map { "\"\($0)\"" } ?? ""
        case .subagent: return input.string("description") ?? ""
        case .skill: return input.string("skill") ?? input.string("command") ?? ""
        default: return ""
        }
    }

    @ViewBuilder private var detail: some View {
        switch call.kind {
        case .bash:
            VStack(alignment: .leading, spacing: 6) {
                CodeBlock(code: "$ " + (input.string("command") ?? ""), language: "bash")
                output
            }
        case .fileEdit:
            if let old = input.string("old_string"), let new = input.string("new_string") {
                DiffView(old: old, new: new)
            } else if let edits = input["edits"]?.arrayValue {
                VStack(alignment: .leading) {
                    ForEach(Array(edits.enumerated()), id: \.offset) { _, e in
                        DiffView(old: e.string("old_string") ?? "", new: e.string("new_string") ?? "")
                    }
                }
            }
            if call.isError == true { output }
        case .fileWrite:
            CodeBlock(code: input.string("content") ?? "", language: (input.string("file_path") ?? "").lastPathComponent, lineLimit: 16)
        case .todoWrite:
            TodoListView(todos: input["todos"]?.arrayValue ?? [])
        case .subagent:
            VStack(alignment: .leading, spacing: 8) {
                if let p = input.string("prompt") {
                    Text(p).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 3)
                }
                let children = thread.children(of: call.id)
                if !children.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(children, id: \.id) { ItemView(item: $0, thread: thread) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                }
                if call.status != .running { output }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                if input.objectValue?.isEmpty == false {
                    CodeBlock(code: input.pretty, language: "input", lineLimit: 12)
                }
                output
            }
        }
    }

    @ViewBuilder private var output: some View {
        if let text = call.outputText, !text.isEmpty {
            CodeBlock(code: text, language: call.isError == true ? "error" : "output", lineLimit: 14)
        }
    }
}

/// A folded run of consecutive, unremarkable finished tool calls (see `foldTranscriptRows`),
/// shown as one quiet "Used N tools" line. Expanding it reveals the individual calls, each
/// still its own `ToolCallView` — expanding one of those shows that call's detail exactly as
/// it would if it weren't part of a group.
struct ToolCallGroupView: View {
    let calls: [Item.ToolCall]
    let thread: ThreadModel
    @State private var expanded: Bool

    init(calls: [Item.ToolCall], thread: ThreadModel, initiallyExpanded: Bool = false) {
        self.calls = calls
        self.thread = thread
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack").foregroundStyle(.secondary).frame(width: 16)
                    Text("Used \(calls.count) tools").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calls, id: \.id) { ToolCallView(call: $0, thread: thread) }
                }
                .padding(.leading, 24)
            }
        }
    }
}

struct TodoListView: View {
    let todos: [JSONValue]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, t in
                let status = t.string("status") ?? "pending"
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(status == "completed" ? .green : status == "in_progress" ? .blue : .secondary)
                    Text(status == "in_progress" ? (t.string("activeForm") ?? t.string("content") ?? "") : (t.string("content") ?? ""))
                        .strikethrough(status == "completed")
                        .foregroundStyle(status == "completed" ? .secondary : .primary)
                }
                .font(.callout)
            }
        }
    }
}

/// Line diff between two strings (removed in red, added in green); collapses past `lineLimit` lines.
struct DiffView: View {
    let old: String
    let new: String
    var lineLimit = 24
    @State private var expanded = false

    private struct Line: Hashable { let sign: Character; let text: String }

    private var lines: [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append(Line(sign: "-", text: a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { out.append(Line(sign: "+", text: b[j])); j += 1 }
            else {
                if j < b.count { out.append(Line(sign: " ", text: b[j])) }
                i += 1; j += 1
            }
        }
        return out
    }

    var body: some View {
        let all = lines
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((expanded ? all : Array(all.prefix(lineLimit))).enumerated()), id: \.offset) { _, l in
                Text(verbatim: "\(l.sign) \(l.text)")
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(l.sign == "-" ? Color.red.opacity(0.14) : l.sign == "+" ? Color.green.opacity(0.14) : .clear)
            }
            if all.count > lineLimit {
                Button(expanded ? "Show Less" : "Show All \(all.count) Lines") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(8)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .background(.fill.quinary, in: .rect(cornerRadius: 8))
    }
}

#if DEBUG
#Preview("Bash tool call") {
    ToolCallView(call: .sample(name: "Bash", kind: .bash,
                                input: ["command": "swift test --filter ThreadModelTests", "description": "Run ThreadModel tests"],
                                status: .completed, outputText: "Test Suite 'ThreadModelTests' passed.\nExecuted 6 tests, with 0 failures.", secondsAgo: 30),
                 thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("File edit") {
    ToolCallView(call: .sample(name: "Edit", kind: .fileEdit, input: [
        "file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherKit/ThreadModel.swift",
        "old_string": "    public private(set) var lastSeq = 0",
        "new_string": "    public private(set) var lastSeq = 0\n    public private(set) var isPreview = false",
    ], status: .completed, secondsAgo: 30), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("File read") {
    ToolCallView(call: .sample(name: "Read", kind: .fileRead,
                                input: ["file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherUI/ItemViews.swift"],
                                status: .completed, secondsAgo: 30), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("Grep") {
    ToolCallView(call: .sample(name: "Grep", kind: .grep, input: ["pattern": "upsertTurn", "path": "TetherKit/Sources/TetherKit"],
                                status: .completed, outputText: "ThreadModel.swift:145:    private func upsertTurn(_ t: Turn) {", secondsAgo: 30),
                 thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("Todo list") {
    ToolCallView(call: .sample(name: "TodoWrite", kind: .todoWrite, input: ["todos": [
        ["content": "Add PreviewSupport.swift", "activeForm": "Adding PreviewSupport.swift", "status": "completed"],
        ["content": "Add #Preview blocks to every TetherUI view", "activeForm": "Adding #Preview blocks", "status": "in_progress"],
        ["content": "Render every preview in Xcode and fix issues", "activeForm": "Rendering previews", "status": "pending"],
    ]], status: .completed, secondsAgo: 30), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

// #Preview bodies are result-builder closures (no `guard`/control flow), so this pulls the
// subagent's `Item.ToolCall` out of the gallery thread for the preview below.
@MainActor
private func sampleSubagentCall(in thread: ThreadModel) -> Item.ToolCall {
    guard case .toolCall(let t) = thread.items.first(where: { $0.id == "tool-subagent-explore" }) else { fatalError("missing sample subagent call") }
    return t
}

#Preview("Subagent (running, with children)") {
    let thread = ThreadModel.sampleToolCalls()
    ToolCallView(call: sampleSubagentCall(in: thread), thread: thread)
        .padding(20)
        .frame(width: 560)
}

#Preview("MCP call") {
    ToolCallView(call: .sample(name: "mcp__xcode__RenderPreview", kind: .mcp, input: ["file": "ItemViews.swift", "preview": "Bash tool call"],
                                status: .completed, outputText: "Rendered 1 preview.", secondsAgo: 30), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("Other / denied") {
    ToolCallView(call: .sample(name: "NotebookRead", kind: .other, input: ["notebook_path": "/Users/hayden/Code/tether-app/notes.ipynb"],
                                status: .denied, secondsAgo: 30), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("Failed") {
    ToolCallView(call: .sample(name: "Bash", kind: .bash, input: ["command": "./scripts/deploy.sh production"], status: .failed,
                                outputText: "Error: SSH connection to deploy-01 timed out", isError: true, secondsAgo: 30), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

// #Preview bodies can't have `let`/control flow either, so this builds the sample run of
// finished calls the two group previews below both use.
@MainActor
private func sampleFinishedRun() -> [Item.ToolCall] {
    [
        .sample(name: "Read", kind: .fileRead, input: ["file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherUI/ThreadView.swift"],
                status: .completed, secondsAgo: 40),
        .sample(name: "Grep", kind: .grep, input: ["pattern": "TranscriptView"], status: .completed,
                outputText: "ThreadView.swift:74:    ForEach(foldTranscriptRows(thread.topLevelItems), id: \\.id) { row in", secondsAgo: 36),
        .sample(name: "Edit", kind: .fileEdit, input: [
            "file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherUI/ThreadView.swift",
            "old_string": "ForEach(thread.topLevelItems, id: \\.id) { item in",
            "new_string": "ForEach(foldTranscriptRows(thread.topLevelItems), id: \\.id) { row in",
        ], status: .completed, secondsAgo: 30),
        .sample(name: "Bash", kind: .bash, input: ["command": "swift build", "description": "Build TetherKit"],
                status: .completed, outputText: "Build complete!", secondsAgo: 24),
        .sample(name: "Read", kind: .fileRead, input: ["file_path": "/Users/hayden/Code/tether-app/TetherKit/Sources/TetherUI/ItemViews.swift"],
                status: .completed, secondsAgo: 18),
    ]
}

#Preview("Tool group (collapsed)") {
    ToolCallGroupView(calls: sampleFinishedRun(), thread: .sampleIdleChat())
        .padding(20)
        .frame(width: 560)
}

#Preview("Tool group (expanded)") {
    ToolCallGroupView(calls: sampleFinishedRun(), thread: .sampleIdleChat(), initiallyExpanded: true)
        .padding(20)
        .frame(width: 560)
}

#Preview("Running call beside a finished group") {
    VStack(alignment: .leading, spacing: 10) {
        ToolCallGroupView(calls: sampleFinishedRun(), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Bash", kind: .bash, input: ["command": "swift test", "description": "Run the test suite"],
                                    status: .running, elapsedSeconds: 4, secondsAgo: 4), thread: .sampleIdleChat())
    }
    .padding(20)
    .frame(width: 560)
}

#Preview("Todo list (standalone)") {
    TodoListView(todos: [
        ["content": "Add PreviewSupport.swift", "status": "completed"],
        ["content": "Add #Preview blocks", "activeForm": "Adding #Preview blocks", "status": "in_progress"],
        ["content": "Render every preview", "status": "pending"],
    ])
    .padding(20)
    .frame(width: 420)
}

#Preview("Diff") {
    DiffView(old: "func title() -> String {\n    return name\n}", new: "func title() -> String {\n    guard !name.isEmpty else { return \"Untitled\" }\n    return name\n}")
        .padding(20)
        .frame(width: 480)
}

#endif
