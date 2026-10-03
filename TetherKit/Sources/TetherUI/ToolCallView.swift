import SwiftUI
import TetherKit
import TetherProtocol

/// One quiet transcript line for a tool call, starting where the reply's text does and reading as
/// what it did ("Read RootView.swift"), expanding to kind-specific detail. A call that failed, was
/// denied or stopped says why on a line beneath, in gray: an agent's missteps are ordinary, and it
/// usually recovers on its own, so nothing about them is loud.
struct ToolCallView: View {
    let call: Item.ToolCall
    let thread: ThreadModel
    @State private var expanded = false
    /// A group-level action can open every call without repeated disclosure clicks.
    var expandDetails = false
    @Environment(\.inspectSubagent) private var inspectSubagent
    @Environment(\.hostIsLocal) private var hostIsLocal
    @Environment(\.openFilesWith) private var editor

    private var input: JSONValue { call.input }

    /// The file the call worked on, for Open, Show in Finder and Copy Path.
    private var filePath: String? {
        switch call.kind {
        case .fileRead, .fileWrite, .fileEdit, .notebookEdit: input.string("file_path") ?? input.string("notebook_path")
        default: nil
        }
    }

    @ViewBuilder private var menu: some View {
        if let path = filePath {
            if hostIsLocal {
                Button(editor.openTitle) { editor.open(path) }
                Button("Show in Finder") { Finder.reveal(path) }
                Divider()
            }
            Button("Copy Path") { Clipboard.copy(path) }
        }
        if call.kind == .bash, let command = input.string("command") {
            Button("Copy Command") { Clipboard.copy(command) }
        }
        if let output = call.outputText, !output.isEmpty {
            Button("Copy Output") { Clipboard.copy(output) }
        }
    }

    var body: some View {
        if call.kind == .subagent {
            // A subagent opens in the inspector instead of here.
            VStack(alignment: .leading, spacing: 2) {
                Button { inspectSubagent(call.id) } label: {
                    HStack(spacing: 8) {
                        header
                        Image(systemName: "sidebar.trailing").scaledFont(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(statusDescription)
                .accessibilityIdentifier("transcript.toolCall")
                reasonLine
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                detailBox
            } label: {
                header
            }
            .disclosureGroupStyle(TranscriptDisclosureStyle(identifier: "transcript.toolCall", value: statusDescription,
                                                            note: ToolCallText.reason(call)))
            .onChange(of: expandDetails, initial: true) { _, open in expanded = open }
        }
    }

    @ViewBuilder private var reasonLine: some View {
        if let reason = ToolCallText.reason(call) {
            Text(reason)
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var detailBox: some View {
        detail
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    /// Words first, then the status, then the disclosure's chevron. A finished call has no status
    /// glyph. Its menu and full command or path are on the words.
    private var header: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).fontWeight(.medium)
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
            }
            if let s = call.elapsedSeconds, call.status == .running {
                Text(Format.duration(s)).scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            status
        }
        .scaledFont(.callout)
        .contextMenu { menu }
        .help(ToolCallText.fullObject(call) ?? "")
        .draggableFile(hostIsLocal ? filePath : nil)
    }

    /// A spinner while it runs, a glyph when it went wrong, and nothing once it's done.
    @ViewBuilder private var status: some View {
        switch call.status {
        case .pending, .running:
            // Hidden, or the whole row reads as a progress indicator rather than a button; its
            // value says it's running instead.
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.tertiary).scaledFont(.caption)
        case .denied: Image(systemName: "hand.raised").foregroundStyle(.tertiary).scaledFont(.caption)
        case .interrupted: Image(systemName: "stop.circle").foregroundStyle(.tertiary).scaledFont(.caption)
        default: EmptyView()
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
        guard call.kind == .subagent else { return ToolCallText.verb(call) }
        return SubagentLifecycle.title(
            call: call,
            task: thread.taskEvent(forToolUseId: call.id),
            isBackgrounded: thread.isTaskBackgrounded(toolUseId: call.id)
        )
    }

    private var subtitle: String { ToolCallText.object(call) }

    @ViewBuilder private var detail: some View {
        switch call.kind {
        case .bash:
            VStack(alignment: .leading, spacing: 6) {
                CodeBlock(code: "$ " + (input.string("command") ?? ""), language: "Command")
                output
            }
        case .fileEdit:
            Text("Changes").scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary)
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
                    CodeBlock(code: PrettyInput.text(for: call.id, input), language: "Input", lineLimit: 12)
                }
                output
            }
        }
    }

    @ViewBuilder private var output: some View {
        if let text = call.outputText, !text.isEmpty {
            CodeBlock(code: text, language: call.isError == true ? "Error Output" : "Output", lineLimit: 14)
        }
    }
}

/// Shows a subagent's call in the window's Tasks pane. Holds the window, not a closure, so it's
/// equal whenever it's the same window and the shell's updates don't redraw every tool call.
struct InspectSubagentAction: Equatable {
    weak var window: WindowModel?

    @MainActor func callAsFunction(_ toolUseId: String) { window?.inspectSubagent(toolUseId) }

    static func == (a: Self, b: Self) -> Bool { a.window === b.window }
}

extension EnvironmentValues {
    @Entry var inspectSubagent = InspectSubagentAction()

    /// The row id of the turn's work a row is shown inside, for Find in Chat.
    @Entry var findFold: String?
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

/// A transcript row that opens, as a disclosure group: its words with the chevron right after them,
/// and what it holds beneath at the same leading edge, so nothing indents. VoiceOver hears whether
/// it's open along with the row's own value (a call's status, a file's line counts).
struct TranscriptDisclosureStyle: DisclosureGroupStyle {
    /// Between the row and what it holds.
    var spacing: CGFloat = 6
    /// The row's accessibility identifier, for UI tests.
    var identifier = "transcript.disclosure"
    var value: String?
    /// A line under the row whether it's open or not: why a call failed.
    var note: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.15)) { configuration.isExpanded.toggle() }
                } label: {
                    // The words, then the chevron right after them.
                    HStack(spacing: 6) {
                        configuration.label
                        DisclosureIndicator(expanded: configuration.isExpanded)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // After the row's words: a disclosure triangle's value is whether it's open, so a
                // value set here never reached VoiceOver ("Running", a file's line counts).
                .accessibilityLabel { label in
                    label
                    if let value, !value.isEmpty { Text(value) }
                }
                .accessibilityIdentifier(identifier)
                if let note {
                    Text(note)
                        .scaledFont(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

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

/// A folded run of finished tool calls (see `foldTranscriptRows`) as one line that says what they
/// did: "Read 3 files, searched code, and ran 2 commands". Open, its calls are listed beneath at
/// the same leading edge, each a line of its own; a failed one has its own gray glyph.
struct ToolCallGroupView: View {
    let calls: [Item.ToolCall]
    let thread: ThreadModel
    /// The transcript row's id, so Find in Chat opens the group when it's the current match.
    var rowID: String?
    @State private var expanded: Bool
    @State private var expandAll = false

    /// While the run is the turn's work in progress, what it's doing now: the running call's words,
    /// or Thinking once its calls are done and nothing has come after them. Nil once it's settled.
    private var liveTitle: String? {
        if let running = calls.last(where: { $0.status == .running || $0.status == .pending }) {
            let object = ToolCallText.object(running)
            return object.isEmpty ? ToolCallText.verb(running) : "\(ToolCallText.verb(running)) \(object)"
        }
        if thread.isThinking, let last = calls.last, thread.lastShownItem?.id == last.id { return "Thinking" }
        return nil
    }

    init(calls: [Item.ToolCall], thread: ThreadModel, rowID: String? = nil, initiallyExpanded: Bool = false) {
        self.calls = calls
        self.thread = thread
        self.rowID = rowID
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("^[\(calls.count) Tool Call](inflect: true)").scaledFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(expandAll ? "Collapse All" : "Expand All") { expandAll.toggle() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .accessibilityIdentifier("transcript.expandTools")
                }
                ForEach(calls, id: \.id) { call in
                    VStack(alignment: .leading, spacing: 8) {
                        ToolCallView(call: call, thread: thread, expandDetails: expandAll)
                        if call.id != calls.last?.id { Divider() }
                    }
                }
            }
            .padding(12)
            .background(.fill.quinary, in: .rect(cornerRadius: 10))
        } label: {
            ActivityLabel(text: liveTitle ?? ToolCallText.summary(calls), live: liveTitle != nil)
                .fontWeight(.medium)
                .scaledFont(.callout)
        }
        .disclosureGroupStyle(TranscriptDisclosureStyle(identifier: "transcript.toolGroup", value: liveTitle == nil ? nil : "Running"))
        .modifier(OpensForFind(rowID: rowID, expanded: $expanded,
                               matches: { TranscriptRow.toolGroup(calls).matches($0) }))
    }
}

/// A finished turn's work folded behind its last message (Settings ▸ Advanced ▸ Tool Calls ▸
/// Worked For): "Worked for 3m 12s". Open, the work is shown as
/// Summarized shows it, at the same leading edge.
struct TurnWorkView: View {
    let rows: [TranscriptRow]
    let durationMs: Double?
    let thread: ThreadModel
    /// The transcript row's id, so Find in Chat opens the work when it's the current match.
    var rowID: String?
    @State private var expanded = false

    private var title: String {
        guard let durationMs, durationMs >= 1000 else { return "Worked" }
        return "Worked for \(Format.duration(durationMs / 1000))"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.id) { TranscriptRowView(row: $0, thread: thread) }
                    // A run of calls in here that holds the match opens too.
                    .environment(\.findFold, rowID)
            }
        } label: {
            Text(title).foregroundStyle(.secondary)
                .scaledFont(.callout)
        }
        .disclosureGroupStyle(TranscriptDisclosureStyle(spacing: 10, identifier: "transcript.turnWork"))
        .modifier(OpensForFind(rowID: rowID, expanded: $expanded))
    }
}

/// Opens a folded row (a run of calls, a turn's work) when Find in Chat makes it the current match,
/// so what matched is on screen and not behind the fold. Find searches exactly the rows the
/// transcript shows, so a match inside a turn's work is the work's row; a run of calls inside it
/// that holds the match opens with it.
private struct OpensForFind: ViewModifier {
    let rowID: String?
    @Binding var expanded: Bool
    /// Whether the row's contents match a query, for a run of calls inside a turn's work.
    var matches: ((String) -> Bool)?
    @Environment(\.transcriptFind) private var find
    @Environment(\.findFold) private var fold

    private var isCurrent: Bool {
        guard let find, let current = find.current else { return false }
        if current == rowID { return true }
        return fold != nil && current == fold && matches?(find.query) == true
    }

    func body(content: Content) -> some View {
        content.onChange(of: isCurrent, initial: true) { _, isCurrent in
            guard isCurrent, !expanded else { return }
            withAnimation(.snappy(duration: 0.15)) { expanded = true }
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
                        .contentTransition(.symbolEffect(.replace))
                        // The row's value says it, once.
                        .accessibilityHidden(true)
                    Text(status == "in_progress" ? (t.string("activeForm") ?? t.string("content") ?? "") : (t.string("content") ?? ""))
                        .strikethrough(status == "completed")
                        .foregroundStyle(status == "completed" ? .secondary : .primary)
                }
                .scaledFont(.callout)
                .animation(.default, value: status)
                // Said, not only drawn: the glyph and the strikethrough are all a row has for it.
                .accessibilityElement(children: .combine)
                .accessibilityValue(status == "completed" ? "Done" : status == "in_progress" ? "In Progress" : "To Do")
            }
        }
    }
}

/// Line diff between two strings (removed in red, added in green); collapses past `lineLimit` lines.
/// Each run of lines of one kind is one text on one tint, not a view per line.
struct DiffView: View {
    let old: String
    let new: String
    var lineLimit = 24
    @State private var expanded = false
    /// A large diff, worked out off the main actor: it's O(old × new).
    @State private var loaded: Loaded?
    // Cached: the transcript redraws on every streamed delta.
    @State private var cache = DiffCache()

    struct Line: Hashable { let sign: Character; let text: String }

    /// Consecutive lines of one kind.
    struct Run: Hashable, Identifiable, Sendable {
        let id: Int
        let sign: Character
        /// The lines as drawn, each with its sign.
        let text: String
        /// The lines without their signs, for VoiceOver, which says the kind instead.
        let spoken: String
    }

    /// The diff's runs, whole and as shown collapsed.
    struct Diff: Sendable {
        let lineCount: Int
        let all: [Run]
        let collapsed: [Run]
    }

    struct Key: Equatable, Sendable {
        let old: String
        let new: String
    }

    private struct Loaded {
        let key: Key
        let lineLimit: Int
        let diff: Diff
    }

    /// The same comparison the edited-files row counts with (`LineDiff`), as signed lines.
    nonisolated static func diff(old: String, new: String) -> [Line] {
        LineDiff.lines(old: old, new: new).map { line in
            switch line.kind {
            case .removed: Line(sign: "-", text: line.text)
            case .added: Line(sign: "+", text: line.text)
            case .context: Line(sign: " ", text: line.text)
            }
        }
    }

    nonisolated static func runs(_ lines: some Collection<Line>) -> [Run] {
        var runs: [Run] = []
        var current: [Line] = []
        func close() {
            guard let sign = current.first?.sign else { return }
            runs.append(Run(id: runs.count, sign: sign,
                            text: current.map { "\($0.sign) \($0.text)" }.joined(separator: "\n"),
                            spoken: current.map(\.text).joined(separator: "\n")))
            current = []
        }
        for line in lines {
            if line.sign != current.first?.sign { close() }
            current.append(line)
        }
        close()
        return runs
    }

    nonisolated static func diff(_ key: Key, lineLimit: Int) -> Diff {
        let lines = diff(old: key.old, new: key.new)
        return Diff(lineCount: lines.count, all: runs(lines), collapsed: runs(lines.prefix(lineLimit)))
    }

    @concurrent
    private nonisolated static func diffOffMain(_ key: Key, lineLimit: Int) async -> Diff {
        diff(key, lineLimit: lineLimit)
    }

    /// Nearly every edit is a few lines, worked out at once so it's drawn with its row; a larger one
    /// is worked out off the main actor.
    private static func isSmall(_ key: Key) -> Bool { key.old.utf8.count + key.new.utf8.count <= 16 * 1024 }

    var body: some View {
        let key = Key(old: old, new: new)
        let diff = Self.isSmall(key) ? cache.diff(key, lineLimit: lineLimit)
            : loaded.flatMap { $0.lineLimit == lineLimit && $0.key == key ? $0.diff : nil }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.map { expanded ? $0.all : $0.collapsed } ?? []) { run in
                Text(verbatim: run.text)
                    .scaledFont(.callout, design: .monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(run.sign == "-" ? Color.red.opacity(0.14) : run.sign == "+" ? Color.green.opacity(0.14) : .clear)
                    // The sign and the tint, in words.
                    .accessibilityLabel(run.sign == "-" ? "Removed" : run.sign == "+" ? "Added" : "Unchanged")
                    .accessibilityValue(run.spoken)
                    .accessibilityTextContentType(.sourceCode)
            }
            if let diff, diff.lineCount > lineLimit {
                Button(expanded ? "Show Less" : "Show All \(diff.lineCount) Lines") { expanded.toggle() }
                    .buttonStyle(.link)
                    .scaledFont(.caption)
                    .padding(8)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .background(.fill.quinary, in: .rect(cornerRadius: 8))
        .task(id: key) {
            guard !Self.isSmall(key), loaded?.key != key || loaded?.lineLimit != lineLimit else { return }
            let diff = await Self.diffOffMain(key, lineLimit: lineLimit)
            guard !Task.isCancelled else { return }
            loaded = Loaded(key: key, lineLimit: lineLimit, diff: diff)
        }
    }
}

/// Memoizes one diff for the life of its view.
@MainActor
final class DiffCache {
    private var key: (diff: DiffView.Key, lineLimit: Int)?
    private var cached: DiffView.Diff?

    func diff(_ key: DiffView.Key, lineLimit: Int) -> DiffView.Diff {
        if let cached, let known = self.key, known.lineLimit == lineLimit, known.diff == key { return cached }
        let diff = DiffView.diff(key, lineLimit: lineLimit)
        self.key = (key, lineLimit)
        cached = diff
        return diff
    }
}

/// Pretty-printed JSON for a tool call's or a request's input, made once per id rather than in every
/// body that shows it: encoding with sorted keys is the slow part of drawing an open call.
@MainActor
enum PrettyInput {
    private static var cache: [String: (input: JSONValue, text: String)] = [:]
    private static var order: [String] = []

    static func text(for id: String, _ input: JSONValue) -> String {
        // Compared, since a running call's input can still change; equal values usually share storage.
        if let hit = cache[id], hit.input == input { return hit.text }
        let text = input.pretty
        if cache.updateValue((input, text), forKey: id) == nil {
            order.append(id)
            if order.count > 200 { cache[order.removeFirst()] = nil }
        }
        return text
    }
}

#if DEBUG
#Preview("Bash tool call") {
    ToolCallView(call: .sample(name: "Bash", kind: .bash,
                                input: ["command": "swift test --filter ThreadModelTests", "description": "Run ThreadModel tests"],
                                status: .completed, outputText: "Test Suite 'ThreadModelTests' passed.\nExecuted 6 tests, with 0 failures.", secondsAgo: 30),
                 thread: .sampleIdleChat(), expandDetails: true)
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

#Preview("Tool calls") {
    VStack(alignment: .leading, spacing: 10) {
        ToolCallGroupView(calls: sampleFinishedRun(), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Bash", kind: .bash, input: ["command": "swift test", "description": "Run the test suite"],
                                    status: .running, elapsedSeconds: 4, secondsAgo: 4), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Edit", kind: .fileEdit, input: ["file_path": "/tmp/a.swift", "old_string": "a", "new_string": "b"],
                                    status: .failed, outputText: "String to replace not found in file.", secondsAgo: 2), thread: .sampleIdleChat())
        ToolCallView(call: .sample(name: "Read", kind: .fileRead, input: ["file_path": "/tmp/b.swift"], status: .completed, secondsAgo: 1),
                     thread: .sampleIdleChat())
    }
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

/// Worked For, with Find in Chat's current match inside the first turn's work: the fold opens.
#Preview("Worked For (opened by a Find match)") {
    FindOpensWorkPreview()
}

private struct FindOpensWorkPreview: View {
    let thread = ThreadModel.sampleWorkChat()
    let find = TranscriptFind()

    var body: some View {
        let rows = thread.rows(.workedFor)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows, id: \.id) { TranscriptRowView(row: $0, thread: thread) }
            }
            .padding(20)
        }
        .environment(\.transcriptFind, find)
        // Opened at once, so the snapshot shows where it ends up.
        .transaction { $0.animation = nil }
        .task {
            find.query = "inspectorMinimum"
            find.update(rows: rows)
        }
        .frame(width: 640, height: 720)
    }
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

/// A line of words that says what's happening: shimmering while it's live, and turning into its
/// next words by blurring up and away as they rise in from below. Settled, it's plain secondary text.
/// Text that turns into its next value the way the running turn's words do: the old blurs up and
/// away as the new blurs in, on a gentle spring. A chat's title as Claude names it.
struct ReplacingText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) { self.text = text }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .id(text)
                .transition(.moving(AnyTransition(BlurReplaceTransition(configuration: .upUp)), reduceMotion: reduceMotion))
        }
        .animation(reduceMotion ? .default : .spring(duration: 0.45, bounce: 0.25), value: text)
    }
}

struct ActivityLabel: View {
    let text: String
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reducesEffects) private var reducesEffects

    var body: some View {
        ZStack(alignment: .leading) {
            words
                .id(text)
                .transition(.moving(AnyTransition(BlurReplaceTransition(configuration: .upUp)), reduceMotion: reduceMotion))
        }
        .lineLimit(1)
        .animation(reduceMotion ? .default : .spring(duration: 0.45, bounce: 0.25), value: text)
    }

    @ViewBuilder private var words: some View {
        if live, !reduceMotion, !reducesEffects {
            // A band of the primary color sweeping across the secondary, every 1.6 s.
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let start = -0.8 + 2.2 * phase
                Text(text).foregroundStyle(LinearGradient(colors: [.secondary, .primary, .secondary],
                                                          startPoint: UnitPoint(x: start, y: 0.5),
                                                          endPoint: UnitPoint(x: start + 0.6, y: 0.5)))
            }
        } else {
            Text(text).foregroundStyle(.secondary)
        }
    }
}
