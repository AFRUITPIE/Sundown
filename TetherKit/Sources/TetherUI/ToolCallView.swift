import SwiftUI
import TetherKit
import TetherProtocol

/// Collapsible card for a tool call, with kind-specific rendering.
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
                Divider().padding(.vertical, 6)
                detail.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor.opacity(0.3)))
    }

    private var alwaysShowBody: Bool {
        call.kind == .todoWrite || (call.kind == .subagent && call.status == .running)
    }

    private var borderColor: Color {
        switch call.status {
        case .failed: return .red
        case .denied: return .orange
        case .running, .pending: return .blue
        default: return .secondary
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title).fontWeight(.medium)
            Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let s = call.elapsedSeconds, call.status == .running {
                Text(Format.duration(s)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            statusIcon
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .font(.callout)
    }

    @ViewBuilder private var statusIcon: some View {
        switch call.status {
        case .pending, .running: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").foregroundStyle(.red)
        case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .interrupted: Image(systemName: "stop.fill").foregroundStyle(.secondary)
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
        case .bash: return "Bash"
        case .fileRead: return "Read"
        case .fileWrite: return "Write"
        case .fileEdit: return "Edit"
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
        case .grep: return input.string("pattern") ?? ""
        case .glob: return input.string("pattern") ?? ""
        case .webFetch: return input.string("url") ?? ""
        case .webSearch: return input.string("query") ?? ""
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
