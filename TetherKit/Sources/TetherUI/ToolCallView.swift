import SwiftUI
import TetherKit
import TetherProtocol

/// One quiet transcript line for a tool call, expanding to kind-specific detail. Color only
/// appears when the call needs attention: failed, denied or still running.
struct ToolCallView: View {
    let call: Item.ToolCall
    let thread: ThreadModel
    @State private var expanded = false
    @Environment(\.inspectSubagent) private var inspectSubagent
    @Environment(\.appearance) private var appearance

    private var input: JSONValue { call.input }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if call.kind == .subagent {
                    inspectSubagent(call.id)
                } else {
                    withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
                }
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The status glyph is inside the label, where VoiceOver doesn't read it.
            .accessibilityValue(statusDescription)
            if call.kind != .subagent, expanded || alwaysShowBody {
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.fill.quinary, in: .rect(cornerRadius: 8))
                    .padding(.top, 6)
                    .padding(.leading, ToolRowLayout.detailInset(appearance))
            }
        }
        // Settings ▸ Appearance ▸ Open Failed Calls: a call that went wrong shows why at once.
        .onAppear(perform: openIfFailed)
        .onChange(of: call.status) { openIfFailed() }
        .onChange(of: appearance.expandFailures) { openIfFailed() }
    }

    private func openIfFailed() {
        guard appearance.expandFailures, call.status == .failed || call.status == .denied, !expanded else { return }
        expanded = true
    }

    private var alwaysShowBody: Bool {
        call.kind == .todoWrite
    }

    /// Chevron, status and icon on the sides Settings ▸ Appearance puts them. A finished call has
    /// no status glyph, just its words.
    private var header: some View {
        HStack(spacing: 8) {
            if appearance.chevronSide == .leading {
                // A subagent opens in the inspector instead: its space is kept so titles line up.
                DisclosureIndicator(expanded: expanded).opacity(call.kind == .subagent ? 0 : 1)
            }
            // Leading, a slot of its own even when empty, so every title starts in the same place.
            if appearance.statusSide == .leading { Color.clear.frame(width: 16, height: 1).overlay { status } }
            if appearance.toolIcons {
                Image(systemName: symbol).foregroundStyle(accentColor).frame(width: 16).accessibilityHidden(true)
            }
            Text(title).foregroundStyle(.secondary)
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if appearance.showElapsed, let s = call.elapsedSeconds, call.status == .running {
                Text(Format.duration(s)).scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if appearance.statusSide == .trailing { status }
            if call.kind == .subagent {
                Image(systemName: "sidebar.trailing").scaledFont(.caption2).foregroundStyle(.tertiary)
            } else if appearance.chevronSide == .trailing {
                DisclosureIndicator(expanded: expanded)
            }
        }
        .scaledFont(.callout)
    }

    /// A spinner while it runs, a glyph when it went wrong, and nothing once it's done.
    @ViewBuilder private var status: some View {
        switch call.status {
        case .pending, .running:
            // Hidden, or the whole row reads as a progress indicator rather than a button; its
            // value says it's running instead.
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).scaledFont(.caption)
        case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).scaledFont(.caption)
        case .interrupted: Image(systemName: "stop.fill").foregroundStyle(.tertiary).scaledFont(.caption2)
        default: EmptyView()
        }
    }

    /// With Settings ▸ Appearance ▸ Show Icons, what kind of work the call is.
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

    private var accentColor: Color {
        switch call.status {
        case .failed: return .red
        case .denied: return .orange
        case .running, .pending: return .blue
        default: return .secondary
        }
    }

    private var statusDescription: String {
        switch call.status {
        case .pending, .running: "Running"
        case .failed: "Failed"
        case .denied: "Denied"
        case .interrupted: "Stopped"
        default: ""
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
        case .subagent:
            return SubagentLifecycle.title(
                call: call,
                task: thread.taskEvent(forToolUseId: call.id),
                isBackgrounded: thread.isTaskBackgrounded(toolUseId: call.id)
            )
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
            EmptyView() // Subagent transcripts belong in the Tasks inspector.
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

/// Equal when the same owner made it, whatever the closure: the shell makes a new one each time its
/// body runs, and a changed environment value redraws every tool call in the transcript.
struct InspectSubagentAction: Sendable, Equatable {
    private let owner: ObjectIdentifier?
    private let open: @MainActor @Sendable (String) -> Void

    init(owner: AnyObject?, open: @escaping @MainActor @Sendable (String) -> Void) {
        self.owner = owner.map(ObjectIdentifier.init)
        self.open = open
    }

    @MainActor func callAsFunction(_ toolUseId: String) { open(toolUseId) }

    static func == (a: Self, b: Self) -> Bool { a.owner == b.owner }
}

private struct InspectSubagentKey: EnvironmentKey {
    static let defaultValue = InspectSubagentAction(owner: nil, open: { _ in })
}

extension EnvironmentValues {
    var inspectSubagent: InspectSubagentAction {
        get { self[InspectSubagentKey.self] }
        set { self[InspectSubagentKey.self] = newValue }
    }
}

enum SubagentLifecycle {
    static func title(call: Item.ToolCall, task: TaskEventNotification?, isBackgrounded: Bool = false) -> String {
        let state = (task?.status ?? task?.event ?? call.status.rawValue).lowercased()
        if isBackgrounded || state.contains("background") { return "Agent running in background" }
        if state.contains("fail") { return "Agent failed" }
        if state.contains("stop") || state.contains("interrupt") { return "Agent stopped" }
        if state.contains("complete") || state.contains("finish") { return "Agent finished" }
        if state.contains("start") || state.contains("progress") || state.contains("running") || state.contains("pending") {
            return "Agent running"
        }
        return "Agent"
    }

    static func isRunning(call: Item.ToolCall?, task: TaskEventNotification?) -> Bool {
        let state = (task?.status ?? task?.event ?? call?.status.rawValue ?? "").lowercased()
        return !state.contains("complete") && !state.contains("finish") && !state.contains("fail")
            && !state.contains("stop") && !state.contains("interrupt") && state != ""
    }
}

/// A folded run of finished tool calls (see `foldTranscriptRows`) as one "Used N tools" line.
/// The expand chevron at a row's trailing end: pointing to the trailing side while closed and down
/// while open.
struct DisclosureIndicator: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .scaledFont(.caption2, weight: .bold)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 10)
            .accessibilityHidden(true)
    }
}

/// Where a tool row's detail starts: under its title, past whatever leads the row.
enum ToolRowLayout {
    static func detailInset(_ appearance: Appearance) -> CGFloat {
        var inset: CGFloat = 0
        if appearance.chevronSide == .leading { inset += 18 }
        if appearance.statusSide == .leading { inset += 24 }
        if appearance.toolIcons { inset += 24 }
        return max(inset, 12)
    }
}

struct ToolCallGroupView: View {
    let calls: [Item.ToolCall]
    let thread: ThreadModel
    @State private var expanded: Bool
    @Environment(\.appearance) private var appearance

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
                    if appearance.chevronSide == .leading { DisclosureIndicator(expanded: expanded) }
                    if appearance.statusSide == .leading { Color.clear.frame(width: 16, height: 1) }
                    if appearance.toolIcons {
                        Image(systemName: "square.stack").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                    }
                    Text("Used \(calls.count) tools").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if appearance.chevronSide == .trailing { DisclosureIndicator(expanded: expanded) }
                }
                .scaledFont(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calls, id: \.id) { ToolCallView(call: $0, thread: thread) }
                }
                // The group's calls indented under it.
                .padding(.leading, ToolRowLayout.detailInset(appearance))
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
                .scaledFont(.callout)
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
    // Cached: the diff is O(old × new) and the transcript redraws on every streamed delta.
    @State private var cache = DiffCache()

    struct Line: Hashable { let sign: Character; let text: String }

    static func diff(old: String, new: String) -> [Line] {
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
        let all = cache.lines(old: old, new: new)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((expanded ? all : Array(all.prefix(lineLimit))).enumerated()), id: \.offset) { _, l in
                Text(verbatim: "\(l.sign) \(l.text)")
                    .scaledFont(.callout, design: .monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(l.sign == "-" ? Color.red.opacity(0.14) : l.sign == "+" ? Color.green.opacity(0.14) : .clear)
            }
            if all.count > lineLimit {
                Button(expanded ? "Show Less" : "Show All \(all.count) Lines") { expanded.toggle() }
                    .buttonStyle(.link)
                    .scaledFont(.caption)
                    .padding(8)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .background(.fill.quinary, in: .rect(cornerRadius: 8))
    }
}

/// Memoizes one diff for the life of its view.
@MainActor
final class DiffCache {
    private var key: (old: String, new: String)?
    private var cached: [DiffView.Line] = []

    func lines(old: String, new: String) -> [DiffView.Line] {
        if let key, key.old == old, key.new == new { return cached }
        cached = DiffView.diff(old: old, new: new)
        key = (old, new)
        return cached
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

// The gallery thread's subagent call, for the preview below.
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

// A run of finished calls for the group previews.
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

/// Settings ▸ Appearance's other tool-call choices: icons, and chevron and status leading.
#Preview("Tool calls (icons, leading)") {
    var appearance = Appearance()
    appearance.toolIcons = true
    appearance.chevronSide = .leading
    appearance.statusSide = .leading
    appearance.expandFailures = true
    return VStack(alignment: .leading, spacing: 10) {
        ToolCallGroupView(calls: sampleFinishedRun(), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Bash", kind: .bash, input: ["command": "swift test", "description": "Run the test suite"],
                                    status: .running, elapsedSeconds: 4, secondsAgo: 4), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Edit", kind: .fileEdit, input: ["file_path": "/tmp/a.swift", "old_string": "a", "new_string": "b"],
                                    status: .failed, outputText: "String to replace not found in file.", secondsAgo: 2), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Read", kind: .fileRead, input: ["file_path": "/tmp/b.swift"], status: .completed, secondsAgo: 1),
                     thread: .sampleIdleChat())
    }
    .environment(\.appearance, appearance)
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
