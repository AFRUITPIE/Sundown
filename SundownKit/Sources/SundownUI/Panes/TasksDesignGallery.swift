#if DEBUG
import Charts
import SwiftUI
import SundownKit
import TetherProtocol

// Debug ▸ Tasks Designs…: every idea for showing tasks (subagents, background commands and large
// dynamic workflows) mocked with fake data, side by side, to choose from. Nothing here is real.

// MARK: - Fake data

enum DesignStatus: Sendable { case queued, running, done, failed, skipped
    var color: Color {
        switch self {
        case .queued: .secondary
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .skipped: .gray
        }
    }
    var label: String {
        switch self {
        case .queued: "Waiting"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }
}

enum DesignKind: Sendable { case agent, command, workflow
    var symbol: String {
        switch self {
        case .agent: "sparkles"
        case .command: "terminal"
        case .workflow: "point.3.connected.trianglepath.dotted"
        }
    }
    var tint: Color {
        switch self {
        case .agent: .purple
        case .command: .gray
        case .workflow: .indigo
        }
    }
    var name: String {
        switch self {
        case .agent: "Agent"
        case .command: "Command"
        case .workflow: "Workflow"
        }
    }
}

struct DesignTask: Identifiable, Sendable {
    let id: String
    let kind: DesignKind
    let name: String
    let status: DesignStatus
    let elapsed: Int
    let tokens: Int
    let tools: Int
    let turn: String
    var lastLine: String
    var activity: [Double]
    var progress: Double?
}

let designTasks: [DesignTask] = [
    .init(id: "w", kind: .workflow, name: "Review the diff for correctness", status: .running, elapsed: 182, tokens: 412_000,
          tools: 0, turn: "Review the Markdown changes before I merge", lastLine: "Verify: 3 of 4 checked",
          activity: [2, 4, 7, 9, 8, 9, 10, 9, 7, 8, 9, 6], progress: 0.56),
    .init(id: "a1", kind: .agent, name: "Find every SwiftUI view in SundownUI", status: .running, elapsed: 100, tokens: 64_000,
          tools: 18, turn: "Which views read thread.items?", lastLine: "Reading ToolCallView.swift",
          activity: [1, 3, 2, 4, 3, 5, 4, 3, 4, 5, 4, 4]),
    .init(id: "c1", kind: .command, name: "swift test --package-path SundownKit", status: .running, elapsed: 52, tokens: 0,
          tools: 0, turn: "Run the tests", lastLine: "✔ Test copyIsPlainText() passed",
          activity: [0, 6, 8, 2, 1, 7, 9, 3, 2, 8, 6, 5]),
    .init(id: "a2", kind: .agent, name: "Research macOS text selection", status: .done, elapsed: 371, tokens: 118_000,
          tools: 4, turn: "Which views read thread.items?", lastLine: "Recommended one text view per message",
          activity: [3, 4, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "c2", kind: .command, name: "xcodebuild -scheme Sundown build", status: .failed, elapsed: 123, tokens: 0,
          tools: 0, turn: "Run the tests", lastLine: "** BUILD FAILED ** (exit 65)",
          activity: [5, 7, 8, 6, 2, 0, 0, 0, 0, 0, 0, 0]),
    .init(id: "a3", kind: .agent, name: "Audit AGENTS.md against the code", status: .skipped, elapsed: 40, tokens: 9_000,
          tools: 2, turn: "Review the Markdown changes before I merge", lastLine: "Stopped",
          activity: [2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
]

struct DesignAgent: Identifiable, Sendable {
    let id: String
    let label: String
    let status: DesignStatus
    let doing: String
    let tokens: Int
    let start: Double
    let end: Double
}

struct DesignPhase: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let agents: [DesignAgent]
    var done: Int { agents.filter { $0.status == .done }.count }
}

/// A workflow of four phases, the second wide: 180 agents in all.
let designPhases: [DesignPhase] = {
    func agents(_ prefix: String, _ count: Int, start: Double, span: Double, running: Int, failed: Int = 0, queued: Int = 0) -> [DesignAgent] {
        (0..<count).map { i in
            let status: DesignStatus = i < count - running - failed - queued ? .done
                : i < count - queued - failed ? .running : i < count - queued ? .failed : .queued
            let s = start + Double((i * 37) % 23) / 23 * span * 0.3
            let e = status == .running ? 182 : status == .queued ? s : s + span * (0.3 + Double((i * 53) % 17) / 17 * 0.7)
            return DesignAgent(id: "\(prefix)-\(i)", label: "\(prefix): \(["bugs", "perf", "a11y", "copy", "layout", "state", "errors", "tests"][i % 8]) \(i / 8 + 1)",
                               status: status, doing: status == .running ? "Reading MarkdownText.swift" : status == .failed ? "Timed out" : status == .queued ? "Waiting" : "\(i % 4) findings",
                               tokens: 4_000 + (i * 733) % 30_000, start: s, end: e)
        }
    }
    return [
        .init(id: "scan", title: "Scan", detail: "List what changed", agents: agents("scan", 4, start: 0, span: 30, running: 0)),
        .init(id: "review", title: "Review", detail: "Each file, each dimension", agents: agents("review", 120, start: 30, span: 90, running: 6, failed: 2)),
        .init(id: "verify", title: "Verify", detail: "Each finding refuted three times", agents: agents("verify", 54, start: 70, span: 110, running: 9, failed: 1, queued: 12)),
        .init(id: "report", title: "Report", detail: "Ranked and written up", agents: agents("report", 2, start: 182, span: 0, running: 0, queued: 2)),
    ]
}()

let designAllAgents = designPhases.flatMap(\.agents)

/// A pipeline() of 18 files through three stages, no barrier between them.
let designPipelineStages = ["Find", "Verify", "Fix"]
let designPipeline: [(item: String, stages: [DesignStatus])] = (0..<18).map { i in
    let files = ["MarkdownText.swift", "Composer.swift", "ItemViews.swift", "TranscriptView.swift", "ThreadModel.swift", "HostConnection.swift"]
    let stage = (i * 7) % 4
    let stages: [DesignStatus] = (0..<3).map { s in
        s < stage ? (i == 5 && s == 1 ? .failed : .done) : s == stage ? (i % 5 == 0 ? .queued : .running) : .queued
    }
    return ("\(files[i % files.count]) #\(i / 6 + 1)", i == 5 ? [.done, .failed, .skipped] : stages)
}

let designLog: [(time: String, text: String)] = [
    ("0:00", "Scanning the diff: 14 files changed"),
    ("0:28", "Reviewing 14 files across 8 dimensions: 120 agents"),
    ("1:09", "41 findings so far, 12 after removing duplicates"),
    ("1:52", "Review finished: 2 agents timed out and were skipped"),
    ("2:10", "Verifying 18 findings, three skeptics each"),
    ("2:58", "Round 3: 2 new findings, 1 quiet round so far"),
]

struct DesignFinding: Identifiable, Sendable {
    let id: Int
    let title: String
    let file: String
    let votes: [Bool] // true = held up
    let finder: String
}

let designFindings: [DesignFinding] = [
    .init(id: 1, title: "A streamed list keeps stale marker widths", file: "MarkdownText.swift:111", votes: [true, true, true], finder: "review: state 3"),
    .init(id: 2, title: "Copy drops tabs for empty table cells", file: "MarkdownText.swift:711", votes: [true, true, false], finder: "review: copy 2"),
    .init(id: 3, title: "Undo can crash after text is set from code", file: "ComposerTextView.swift:105", votes: [true, true, true], finder: "review: bugs 1"),
    .init(id: 4, title: "Esc opens the word completion list", file: "ComposerTextView.swift:155", votes: [true, false, true], finder: "review: a11y 4"),
    .init(id: 5, title: "Find highlights lost after a theme change", file: "MarkdownText.swift:94", votes: [false, false, true], finder: "review: state 7"),
]

private func duration(_ seconds: Int) -> String {
    seconds >= 60 ? "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" : "\(seconds)s"
}

private func tokens(_ n: Int) -> String {
    n >= 1000 ? "\(n / 1000)K" : "\(n)"
}

// MARK: - Pieces

private struct KindIcon: View {
    let kind: DesignKind
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.tint.gradient, in: .rect(cornerRadius: size / 4))
    }
}

private struct StatusDot: View {
    let status: DesignStatus
    var body: some View {
        Group {
            switch status {
            case .running:
                Image(systemName: "circle.fill").resizable().foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)
            case .done: Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.circle.fill").resizable().foregroundStyle(.red)
            case .skipped: Image(systemName: "minus.circle").resizable().foregroundStyle(.secondary)
            case .queued: Image(systemName: "circle.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 10, height: 10)
    }
}

private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(.blue.opacity(0.25)).interpolationMethod(.catmullRom)
            LineMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(.blue).interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(width: 60, height: 18)
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Page<Content: View>: View {
    let note: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Note(text: note)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
    }
}

private struct TaskListRow: View {
    let task: DesignTask
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 10) {
            KindIcon(kind: task.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name).lineLimit(1)
                Text("\(task.kind.name) · \(duration(task.elapsed))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
            StatusDot(status: task.status)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 1–5: Where tasks live

private struct SidebarDetailDesign: View {
    @State private var selection = "w"
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Running") { ForEach(designTasks.filter { $0.status == .running }) { TaskListRow(task: $0).tag($0.id) } }
                Section("Finished") { ForEach(designTasks.filter { $0.status != .running }) { TaskListRow(task: $0).tag($0.id) } }
            }
            .listStyle(.sidebar)
            .frame(width: 270)
            Divider()
            DetailForTask(task: designTasks.first { $0.id == selection } ?? designTasks[0])
        }
    }
}

private struct DetailForTask: View {
    let task: DesignTask
    var body: some View {
        switch task.kind {
        case .workflow: PhaseTimelineDesign()
        case .agent: AgentTranscriptDesign()
        case .command: TerminalDesign(task: task)
        }
    }
}

private struct TableDesign: View {
    @State private var selection: String?
    @State private var order = [KeyPathComparator(\DesignTask.elapsed, order: .reverse)]
    var body: some View {
        VSplitView {
            Table(designTasks.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Name", value: \.name) { t in
                    HStack { KindIcon(kind: t.kind, size: 18); Text(t.name) }
                }
                TableColumn("Status") { t in HStack(spacing: 6) { StatusDot(status: t.status); Text(t.status.label) } }
                    .width(90)
                TableColumn("Elapsed", value: \.elapsed) { Text(duration($0.elapsed)).monospacedDigit() }.width(70)
                TableColumn("Tokens", value: \.tokens) { Text($0.tokens == 0 ? "—" : tokens($0.tokens)).monospacedDigit() }.width(70)
                TableColumn("Tools", value: \.tools) { Text($0.tools == 0 ? "—" : "\($0.tools)").monospacedDigit() }.width(50)
            }
            .frame(minHeight: 200)
            DetailForTask(task: designTasks.first { $0.id == selection } ?? designTasks[0]).frame(minHeight: 260)
        }
    }
}

private struct CardFeedDesign: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(designTasks.filter { $0.status == .running }) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { KindIcon(kind: task.kind, size: 30); VStack(alignment: .leading) { Text(task.name).font(.headline); Text(task.kind.name).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(duration(task.elapsed)).monospacedDigit().foregroundStyle(.secondary) }
                        if let p = task.progress { ProgressView(value: p) }
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(task.lastLine).foregroundStyle(.secondary) }.font(.callout)
                    }
                    .padding(14)
                    .background(.fill.quinary, in: .rect(cornerRadius: 14))
                }
                Text("Finished").font(.headline).padding(.top, 6)
                ForEach(designTasks.filter { $0.status != .running }) { task in
                    HStack { StatusDot(status: task.status); Text(task.name); Spacer(); Text(task.lastLine).foregroundStyle(.secondary).lineLimit(1) }
                        .font(.callout)
                }
            }
        }
    }
}

private struct ByTurnDesign: View {
    var body: some View {
        let turns = Array(Set(designTasks.map(\.turn))).sorted()
        List {
            ForEach(turns, id: \.self) { turn in
                Section {
                    ForEach(designTasks.filter { $0.turn == turn }) { TaskListRow(task: $0) }
                } header: {
                    Label(turn, systemImage: "person.fill").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SummaryStrip: View {
    var body: some View {
        HStack(spacing: 18) {
            Label("3 running", systemImage: "circle.fill").foregroundStyle(.blue)
            Divider().frame(height: 14)
            HStack(spacing: 6) {
                KindIcon(kind: .workflow, size: 16)
                Text("Review in Verify")
                ProgressView(value: 0.56).frame(width: 80)
                Text("5 of 9").monospacedDigit().foregroundStyle(.secondary)
            }
            Divider().frame(height: 14)
            Label("412K tokens", systemImage: "chart.bar.fill")
            Divider().frame(height: 14)
            Label("1 failed", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar, in: .rect(cornerRadius: 12))
    }
}

private struct SummaryStripDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SummaryStrip()
            List(designTasks) { TaskListRow(task: $0) }
        }
    }
}

// MARK: - 6–15: A big workflow

private struct WorkflowHeader: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KindIcon(kind: .workflow, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Review the diff for correctness").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(status: .running); Text("Running · 3m 02s · 180 agents · 412K tokens")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            ControlGroup {
                Button("Show in Chat", systemImage: "text.bubble") {}
                Button("Stop", systemImage: "stop.fill") {}
            }
            .fixedSize()
        }
    }
}

private struct PhaseTimelineDesign: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkflowHeader()
                ProgressView(value: 0.56).tint(.indigo)
                ForEach(Array(designPhases.enumerated()), id: \.element.id) { n, phase in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(phase.done == phase.agents.count ? AnyShapeStyle(.green) : phase.agents.contains { $0.status == .running } ? AnyShapeStyle(.blue) : AnyShapeStyle(.quaternary))
                            Text("\(n + 1)").font(.caption.bold()).foregroundStyle(.white)
                        }
                        .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(phase.title).font(.headline); Text(phase.detail).foregroundStyle(.secondary); Spacer(); Text("\(phase.done) of \(phase.agents.count)").monospacedDigit().foregroundStyle(.secondary) }
                            VStack(spacing: 0) {
                                ForEach(phase.agents.sorted { order($0.status) < order($1.status) }.prefix(4)) { agent in
                                    HStack(spacing: 8) { StatusDot(status: agent.status); Text(agent.label); Text(agent.doing).foregroundStyle(.secondary).lineLimit(1); Spacer(); Text(tokens(agent.tokens)).foregroundStyle(.tertiary).monospacedDigit() }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                }
                                if phase.agents.count > 4 {
                                    Text("and \(phase.agents.count - 4) more").font(.callout).foregroundStyle(.secondary).padding(8)
                                }
                            }
                            .background(.fill.quinary, in: .rect(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }
}

/// Running and failed first: the agents worth a look.
private func order(_ s: DesignStatus) -> Int {
    switch s {
    case .running: 0
    case .failed: 1
    case .queued: 2
    case .done: 3
    case .skipped: 4
    }
}

private struct StatusGridDesign: View {
    @State private var hovered: DesignAgent?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkflowHeader()
                ForEach(designPhases) { phase in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(phase.title).font(.headline); Spacer(); Text("\(phase.done) of \(phase.agents.count)").monospacedDigit().foregroundStyle(.secondary) }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(14), spacing: 4), count: 30), alignment: .leading, spacing: 4) {
                            ForEach(phase.agents) { agent in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(agent.status.color.opacity(agent.status == .queued ? 0.25 : 1))
                                    .frame(width: 14, height: 14)
                                    .onHover { if $0 { hovered = agent } }
                                    .help("\(agent.label) · \(agent.status.label)")
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    ForEach([DesignStatus.running, .done, .failed, .queued], id: \.label) { s in
                        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 10, height: 10); Text(s.label) }
                    }
                    Spacer()
                    if let hovered { Text("\(hovered.label) — \(hovered.doing)").foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
        }
    }
}

private struct PipelineGridDesign: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorkflowHeader()
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow {
                        Text("Item").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(designPipelineStages, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 110) }
                    }
                    ForEach(Array(designPipeline.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.item).font(.callout).lineLimit(1)
                            ForEach(Array(row.stages.enumerated()), id: \.offset) { _, s in
                                HStack(spacing: 4) { StatusDot(status: s); Text(s.label).font(.caption) }
                                    .frame(width: 110, height: 22)
                                    .background(s.color.opacity(s == .queued ? 0.06 : 0.15), in: .rect(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SwimlanesDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowHeader()
            // A sample across every phase, the failed and running ones included.
            let started = designAllAgents.filter { $0.status != .queued }
            let sample = started.enumerated().filter { $0.offset % 3 == 0 || $0.element.status != .done }.map(\.element)
            Chart(sample) { agent in
                BarMark(xStart: .value("Start", agent.start), xEnd: .value("End", max(agent.end, agent.start + 1)), y: .value("Agent", agent.id))
                    .foregroundStyle(agent.status.color.gradient)
                    .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: .stride(by: 30)) { v in AxisGridLine(); AxisValueLabel { if let s = v.as(Double.self) { Text(duration(Int(s))) } } } }
            .chartOverlay { _ in EmptyView() }
            Note(text: "Each bar is an agent, from start to finish; phases overlap where the script pipelines. Blue bars are still running; red ones failed.")
        }
    }
}

private struct PhaseColumnsDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowHeader()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(designPhases) { phase in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(phase.title).font(.headline); Spacer(); Text("\(phase.done)/\(phase.agents.count)").foregroundStyle(.secondary).monospacedDigit() }
                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(phase.agents.sorted { order($0.status) < order($1.status) }.prefix(12)) { agent in
                                        HStack(spacing: 6) { StatusDot(status: agent.status); Text(agent.label).lineLimit(1); Spacer() }
                                            .font(.callout)
                                            .padding(8)
                                            .background(.background, in: .rect(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .frame(width: 220)
                        .background(.fill.quinary, in: .rect(cornerRadius: 12))
                    }
                }
            }
        }
    }
}

private struct NarrationDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkflowHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(designLog.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.time).font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 36, alignment: .trailing)
                            Text(line.text)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("now").font(.callout).foregroundStyle(.tertiary).frame(width: 36, alignment: .trailing)
                        Text("Verifying “Esc opens the word completion list”").foregroundStyle(.secondary).italic()
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            DisclosureGroup("180 agents") { Text("The phases and agents, folded away.").foregroundStyle(.secondary) }
        }
    }
}

private struct ResultsDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { KindIcon(kind: .workflow, size: 32); VStack(alignment: .leading) { Text("Review the diff for correctness").font(.headline); Text("Done · 4 confirmed, 1 refuted · 6m 40s").foregroundStyle(.secondary) } }
            List(designFindings) { f in
                let held = f.votes.filter { $0 }.count
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: held >= 2 ? "checkmark.seal.fill" : "xmark.seal").foregroundStyle(held >= 2 ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).strikethrough(held < 2)
                        HStack(spacing: 8) {
                            Button(f.file) {}.buttonStyle(.link)
                            Text("found by \(f.finder)").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Spacer()
                    HStack(spacing: 2) { ForEach(Array(f.votes.enumerated()), id: \.offset) { Image(systemName: $1 ? "hand.thumbsup.fill" : "hand.thumbsdown").foregroundStyle($1 ? .green : .red) } }
                        .font(.caption)
                        .help("\(held) of \(f.votes.count) skeptics couldn't refute it")
                }
            }
        }
    }
}

private struct FunnelDesign: View {
    let steps: [(String, Int)] = [("Found", 41), ("After duplicates", 18), ("Verified", 9), ("Confirmed", 4)]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkflowHeader()
            ForEach(steps, id: \.0) { name, n in
                HStack {
                    Text(name).frame(width: 130, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 5).fill(.indigo.gradient).frame(width: g.size.width * CGFloat(n) / 41)
                    }
                    .frame(height: 22)
                    Text("\(n)").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
        }
    }
}

private struct BudgetDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkflowHeader()
            Gauge(value: 412, in: 0...500) { Text("Budget") } currentValueLabel: { Text("412K of 500K") }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(.orange)
            Chart {
                ForEach(designPhases) { p in
                    BarMark(x: .value("Tokens", p.agents.reduce(0) { $0 + $1.tokens } / 1000), y: .value("", "Spent"))
                        .foregroundStyle(by: .value("Phase", p.title))
                }
            }
            .frame(height: 60)
            Note(text: "About 88K tokens left: at this rate, two more rounds before the loop has to stop.")
        }
    }
}

private struct RoundsDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkflowHeader()
            HStack(spacing: 10) {
                ForEach(1...4, id: \.self) { r in
                    VStack(spacing: 6) {
                        Text("Round \(r)").font(.caption).foregroundStyle(.secondary)
                        Text(r == 4 ? "…" : "\([9, 5, 2][r - 1])").font(.title.weight(.semibold)).monospacedDigit()
                        Text(r == 4 ? "running" : "new").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 90, height: 90)
                    .background(r == 4 ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.fill.quinary), in: .rect(cornerRadius: 12))
                }
            }
            Label("Stops after 2 rounds with nothing new · 1 quiet round so far", systemImage: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 16–18: A subagent

private struct AgentTranscriptDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentFiguresHeader()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find every SwiftUI view in SundownUI and list which read `thread.items`.")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.purple.opacity(0.18), in: .rect(cornerRadius: 16))
                    Text("Searched code and read 6 files ›").foregroundStyle(.secondary).font(.callout)
                    Text("Most views read `rows`, not `items`. Two exceptions so far: `TranscriptFind` builds its search text from items, and `ThreadView` reads the last item for the Thinking line.")
                    HStack(spacing: 6) { Text("Reading ToolCallView.swift").foregroundStyle(.secondary); ProgressView().controlSize(.mini) }.font(.callout)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AgentFiguresHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KindIcon(kind: .agent, size: 36)
                VStack(alignment: .leading) { Text("Find every SwiftUI view in SundownUI").font(.headline); Text("Explore · in the background").foregroundStyle(.secondary).font(.callout) }
                Spacer()
                Button("Stop", systemImage: "stop.fill") {}
            }
            HStack(spacing: 28) {
                figure("Elapsed", "1m 40s"); figure("Tool Calls", "18"); figure("Tokens", "64K"); figure("Model", "Sonnet")
            }
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading ToolCallView.swift").foregroundStyle(.secondary) }.font(.callout)
        }
        .padding(20)
    }

    private func figure(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(.caption).foregroundStyle(.secondary); Text(v).font(.title3.weight(.medium)).monospacedDigit() }
    }
}

private struct NestedAgentsDesign: View {
    struct Node: Identifiable { let id = UUID(); let name: String; let status: DesignStatus; var children: [Node]? }
    let tree = [
        Node(name: "Plan the migration", status: .running, children: [
            Node(name: "Map the old API", status: .done, children: nil),
            Node(name: "Rewrite call sites", status: .running, children: [
                Node(name: "Sidebar/", status: .done, children: nil),
                Node(name: "Thread/", status: .running, children: nil),
                Node(name: "Settings/", status: .queued, children: nil),
            ]),
            Node(name: "Check the build", status: .queued, children: nil),
        ]),
    ]
    var body: some View {
        List(tree, children: \.children) { node in
            HStack(spacing: 8) { StatusDot(status: node.status); KindIcon(kind: .agent, size: 18); Text(node.name) }
        }
    }
}

// MARK: - 19–20: A command

private struct TerminalDesign: View {
    var task: DesignTask = designTasks[2]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                KindIcon(kind: .command, size: 32)
                Text(task.name).font(.body.monospaced())
                Spacer()
                if task.status == .failed {
                    Text("exit 65").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(.red.opacity(0.2), in: .capsule)
                } else {
                    Text("running").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(.blue.opacity(0.2), in: .capsule)
                }
                ControlGroup {
                    Button("Copy Output", systemImage: "doc.on.doc") {}
                    Button("Open in Terminal", systemImage: "apple.terminal") {}
                    Button("Stop", systemImage: "stop.fill") {}
                }
                .fixedSize()
            }
            .padding(14)
            Divider()
            ScrollView {
                Text("""
                $ \(task.name)
                Building for debugging...
                [42/88] Compiling SundownUI MarkdownText.swift
                [43/88] Compiling SundownUI Composer.swift
                Test Suite 'MarkdownTextTests' started
                ✔ Test everyCharacterHasAStyle() passed (0.001 seconds)
                ✔ Test copyIsPlainText() passed (0.036 seconds)
                """)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .background(.black.opacity(0.25))
        }
    }
}

private struct LastLineRowsDesign: View {
    var body: some View {
        List(designTasks) { task in
            HStack(spacing: 10) {
                KindIcon(kind: task.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.name).lineLimit(1)
                    Text(task.lastLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusDot(status: task.status)
            }
        }
    }
}

// MARK: - 21–23: List rows

private struct RingRowsDesign: View {
    var body: some View {
        List(designTasks) { task in
            TaskListRow(task: task, trailing: task.progress.map { p in
                AnyView(Gauge(value: p) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.45).frame(width: 26, height: 26).tint(.indigo))
            })
        }
    }
}

private struct SparklineRowsDesign: View {
    var body: some View {
        List(designTasks) { task in
            TaskListRow(task: task, trailing: AnyView(Sparkline(values: task.activity)))
        }
    }
}

private struct FailuresFirstDesign: View {
    var body: some View {
        List {
            Section {
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text("2 agents failed in Review, 1 in Verify"); Spacer(); Button("Show") {} }
                ForEach(designAllAgents.filter { $0.status == .failed }) { agent in
                    HStack(spacing: 8) { StatusDot(status: .failed); Text(agent.label); Text(agent.doing).foregroundStyle(.secondary); Spacer(); Button("Retry") {}.controlSize(.small) }
                }
            } header: { Text("Needs a Look") }
            Section("Running") { ForEach(designTasks.filter { $0.status == .running }) { TaskListRow(task: $0) } }
        }
    }
}

// MARK: - 24–28: Acting on tasks

private struct ActionsDesign: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("A phase") {
                HStack {
                    Text("Verify").font(.headline); Text("44 of 54 · 9 running").foregroundStyle(.secondary); Spacer()
                    Menu("Phase", systemImage: "ellipsis.circle") {
                        Button("Stop This Phase", systemImage: "stop") {}
                        Button("Retry Failed Agents", systemImage: "arrow.clockwise") {}
                        Divider()
                        Button("Copy Results", systemImage: "doc.on.doc") {}
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(4)
            }
            GroupBox("An agent") {
                HStack(spacing: 8) {
                    StatusDot(status: .failed); Text("review: perf 9"); Text("Timed out").foregroundStyle(.secondary); Spacer()
                    Button("Retry", systemImage: "arrow.clockwise") {}
                    Button("Open in New Window", systemImage: "macwindow.on.rectangle") {}
                    Button("Show in Chat", systemImage: "text.bubble") {}
                }
                .labelStyle(.iconOnly)
                .padding(4)
            }
            GroupBox("Its context menu") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Open in New Window", "Show in Chat", "Copy Result", "Copy Prompt", "Stop", "Move to Background", "Retry"], id: \.self) { Text($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

private struct SearchFilterDesign: View {
    @State private var query = "a11y"
    @State private var filter = "Running"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search 180 agents", text: $query).textFieldStyle(.roundedBorder).frame(width: 240)
                Picker("", selection: $filter) { ForEach(["All", "Running", "Failed", "Done"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).fixedSize()
                Spacer()
                Text("7 matches").foregroundStyle(.secondary)
            }
            List(designAllAgents.filter { $0.label.contains(query) && (filter == "All" || $0.status.label == (filter == "Running" ? "Running" : filter == "Failed" ? "Failed" : "Done")) }) { agent in
                HStack(spacing: 8) { StatusDot(status: agent.status); Text(agent.label); Text(agent.doing).foregroundStyle(.secondary); Spacer(); Text(tokens(agent.tokens)).foregroundStyle(.tertiary) }
            }
        }
    }
}

// MARK: - The recommended combination

private struct RecommendedDesign: View {
    @State private var tab = "Progress"
    var body: some View {
        HStack(spacing: 0) {
            List {
                Section("Running") {
                    ForEach(designTasks.filter { $0.status == .running }) { task in
                        TaskListRow(task: task, trailing: task.progress.map { p in
                            AnyView(Gauge(value: p) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.45).frame(width: 26, height: 26).tint(.indigo))
                        })
                    }
                }
                Section("Finished") { ForEach(designTasks.filter { $0.status != .running }) { TaskListRow(task: $0) } }
            }
            .listStyle(.sidebar)
            .frame(width: 270)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                SummaryStrip()
                Picker("", selection: $tab) { ForEach(["Progress", "Log", "Result"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).fixedSize()
                switch tab {
                case "Log": NarrationDesign()
                case "Result": ResultsDesign()
                default: StatusGridDesign()
                }
            }
            .padding(16)
        }
    }
}

// MARK: - The gallery

public struct TasksDesignGallery: View {
    public static let id = "tasks-designs"
    public init() {}

    private struct Design: Identifiable, Hashable {
        let id: Int
        let title: String
        let group: String
        let note: String
    }

    private let designs: [Design] = [
        .init(id: 1, title: "Sidebar and Detail", group: "Where Tasks Live", note: "Quiet: each thing said once, in words."),
        .init(id: 2, title: "Activity Monitor Table", group: "Where Tasks Live", note: "Sortable columns, the chosen task's detail in a split below."),
        .init(id: 3, title: "Card Feed", group: "Where Tasks Live", note: "Running tasks as live cards; finished ones as single lines."),
        .init(id: 4, title: "Grouped by Turn", group: "Where Tasks Live", note: "Each task under the prompt that started it."),
        .init(id: 5, title: "Summary Strip", group: "Where Tasks Live", note: "What's going on, in one line across the top."),
        .init(id: 6, title: "Phase Timeline", group: "A Big Workflow", note: "Numbered phases, each with its agents; running and failed first."),
        .init(id: 7, title: "Status Grid", group: "A Big Workflow", note: "Every agent a square, by phase: stays legible at hundreds of agents. Hover for its name."),
        .init(id: 8, title: "Pipeline Grid", group: "A Big Workflow", note: "For pipeline(): items down, stages across, each cell where that item stands."),
        .init(id: 9, title: "Swimlanes", group: "A Big Workflow", note: "Each agent's run over time: parallelism, barriers and stragglers at a glance."),
        .init(id: 10, title: "Phase Columns", group: "A Big Workflow", note: "A board: a column per phase, agents as cards."),
        .init(id: 11, title: "Narration", group: "A Big Workflow", note: "The workflow's log() lines as the story, the agents folded below."),
        .init(id: 12, title: "Results First", group: "A Big Workflow", note: "Once done: the findings, each linked to where it is and who found it, with the skeptics' votes."),
        .init(id: 13, title: "Funnel", group: "A Big Workflow", note: "Found, after duplicates, verified, confirmed."),
        .init(id: 14, title: "Budget", group: "A Big Workflow", note: "Tokens spent against the budget, by phase."),
        .init(id: 15, title: "Rounds", group: "A Big Workflow", note: "A loop-until-dry run as rounds, and when it stops."),
        .init(id: 16, title: "Agent Transcript", group: "A Subagent", note: "Its prompt and work, drawn as the chat draws them."),
        .init(id: 17, title: "Figures and Live Line", group: "A Subagent", note: "The numbers that matter and what it's doing now."),
        .init(id: 18, title: "Nested Agents", group: "A Subagent", note: "Agents an agent started, indented under it."),
        .init(id: 19, title: "Terminal", group: "A Command", note: "Live output at its end, exit status, Copy, Open in Terminal."),
        .init(id: 20, title: "Last Line in Rows", group: "A Command", note: "Each row's latest output, live."),
        .init(id: 21, title: "Progress Rings", group: "List Rows", note: "A workflow's progress on its row."),
        .init(id: 22, title: "Sparklines", group: "List Rows", note: "Recent activity: a stalled task goes flat."),
        .init(id: 23, title: "Failures First", group: "List Rows", note: "What needs a look rises to the top, with Retry."),
        .init(id: 24, title: "Stop, Retry, Open, Show in Chat", group: "Acting on Tasks", note: "Per phase and per agent, and in each agent's context menu."),
        .init(id: 28, title: "Search and Filters", group: "Acting on Tasks", note: "Finding the one agent among hundreds."),
        .init(id: 0, title: "Recommended Combination", group: "Together", note: "Sidebar with rings, a summary strip, and Progress (status grid), Log and Result."),
    ]

    @State private var selection: Int? = 0

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(["Together", "Where Tasks Live", "A Big Workflow", "A Subagent", "A Command", "List Rows", "Acting on Tasks"], id: \.self) { group in
                    Section(group) {
                        ForEach(designs.filter { $0.group == group }) { d in
                            Text(d.id == 0 ? d.title : "\(d.id). \(d.title)").tag(d.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let selection, let design = designs.first(where: { $0.id == selection }) {
                Page(note: design.note) { view(for: design.id) }
                    .navigationTitle(design.title)
                    .navigationSubtitle(design.group)
            }
        }
    }

    @ViewBuilder private func view(for id: Int) -> some View {
        switch id {
        case 1: QuietSidebarDetail()
        case 2: TableDesign()
        case 3: CardFeedDesign()
        case 4: ByTurnDesign()
        case 5: SummaryStripDesign()
        case 6: PhaseTimelineDesign()
        case 7: StatusGridDesign()
        case 8: PipelineGridDesign()
        case 9: SwimlanesDesign()
        case 10: PhaseColumnsDesign()
        case 11: NarrationDesign()
        case 12: ResultsDesign()
        case 13: FunnelDesign()
        case 14: BudgetDesign()
        case 15: RoundsDesign()
        case 16: AgentTranscriptDesign()
        case 17: AgentFiguresHeader()
        case 18: NestedAgentsDesign()
        case 19: TerminalDesign()
        case 20: LastLineRowsDesign()
        case 21: RingRowsDesign()
        case 22: SparklineRowsDesign()
        case 23: FailuresFirstDesign()
        case 24: ActionsDesign()
        case 28: SearchFilterDesign()
        default: RecommendedDesign()
        }
    }
}

/// The app's Debug menu, in debug builds only.
public struct DebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    public init() {}
    public var body: some Commands {
        CommandMenu("Debug") {
            Button("Tasks Designs…") { openWindow(id: TasksDesignGallery.id) }
        }
    }
}
#endif

#if DEBUG
// MARK: - 1, revised: native list and details

/// Counts in words: what's done, running, failed and waiting, never a made-up percentage.
private func counts(_ agents: [DesignAgent]) -> String {
    let n = { (s: DesignStatus) in agents.filter { $0.status == s }.count }
    return [("done", n(.done)), ("running", n(.running)), ("failed", n(.failed)), ("waiting", n(.queued))]
        .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
}

/// What the list can select: a task, a workflow's phase, or one of its agents.
private enum TaskSelection: Hashable {
    case task(String)
    case phase(String)
    case agent(String)
}

private enum TaskFilter: String, CaseIterable { case all = "All", running = "Running", failed = "Failed" }

/// The sidebar's own dot, in words for VoiceOver; nothing for what's simply done.
private func chatState(_ s: DesignStatus) -> ChatState {
    switch s {
    case .running: .working
    case .failed: .failed
    case .skipped: .stopped
    case .queued, .done: .idle
    }
}

private struct RevisedSidebarDetail: View {
    @State private var selection: TaskSelection? = .task("w")
    @State private var expanded: Set<String> = ["w", "review", "verify"]
    /// Phases showing their done agents too.
    @State private var showingDone: Set<String> = []
    @State private var filterText = ""
    @State private var filter = TaskFilter.all

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 290, maxWidth: 400)
            detail
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The list

    private var list: some View {
        VStack(spacing: 0) {
            taskList
            Divider()
            // Xcode's navigators filter at the bottom: the window's toolbar stays the same for
            // every tab.
            VStack(spacing: 6) {
                Picker("Show", selection: $filter) {
                    ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Filter", text: $filterText, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(10)
        }
    }

    private var taskList: some View {
        List(selection: $selection) {
            Section("Running") {
                ForEach(designTasks.filter { $0.status == .running }) { taskRow($0) }
            }
            Section("Finished") {
                ForEach(designTasks.filter { $0.status != .running }) { taskRow($0) }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func taskRow(_ task: DesignTask) -> some View {
        if task.kind == .workflow {
            DisclosureGroup(isExpanded: binding(task.id)) {
                ForEach(designPhases) { phaseRow($0) }
            } label: {
                TaskLabel(title: task.name, subtitle: "Workflow · \(counts(designAllAgents))",
                          state: chatState(task.status))
            }
            .tag(TaskSelection.task(task.id))
            .contextMenu { taskMenu(task) }
        } else {
            TaskLabel(title: task.name, subtitle: subtitle(task), state: chatState(task.status))
                .tag(TaskSelection.task(task.id))
                .contextMenu { taskMenu(task) }
        }
    }

    private func phaseRow(_ phase: DesignPhase) -> some View {
        // What needs a look first: failed, then running, then waiting; done agents on request.
        let agents = phase.agents.filter(matches).sorted { rank($0.status) < rank($1.status) }
        let hidden = agents.filter { $0.status == .done }
        let shown = showingDone.contains(phase.id) ? agents : agents.filter { $0.status != .done }
        return DisclosureGroup(isExpanded: binding(phase.id)) {
            ForEach(shown) { agent in
                TaskLabel(title: agent.label, subtitle: agent.doing, state: chatState(agent.status), compact: true)
                    .tag(TaskSelection.agent(agent.id))
            }
            if !hidden.isEmpty, !showingDone.contains(phase.id) {
                Button("Show \(hidden.count) Done") { showingDone.insert(phase.id) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } label: {
            TaskLabel(title: phase.title, subtitle: counts(phase.agents),
                      state: phase.agents.contains { $0.status == .running } ? .working : .idle)
                .accessibilityAddTraits(.isHeader)
        }
        .tag(TaskSelection.phase(phase.id))
    }

    private func matches(_ agent: DesignAgent) -> Bool {
        (filterText.isEmpty || agent.label.localizedCaseInsensitiveContains(filterText))
            && (filter == .all || (filter == .running ? agent.status == .running : agent.status == .failed))
    }

    private func rank(_ s: DesignStatus) -> Int {
        switch s {
        case .failed: 0
        case .running: 1
        case .queued: 2
        case .skipped: 3
        case .done: 4
        }
    }

    private func subtitle(_ task: DesignTask) -> String {
        switch task.kind {
        case .agent: "Agent · \(task.status.label) · \(duration(task.elapsed))"
        case .command: task.status == .failed ? "Command · Failed, exit code 65" : "Command · \(task.status.label) · \(duration(task.elapsed))"
        case .workflow: "Workflow"
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding { expanded.contains(id) } set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
    }

    @ViewBuilder private func taskMenu(_ task: DesignTask) -> some View {
        Button("Show in Chat") {}
        if task.kind == .command { Button("Copy Output") {} }
        if task.status == .running {
            if task.kind != .workflow { Button("Move to Background") {} }
            Divider()
            Button("Stop", role: .destructive) {}
        }
    }

    // MARK: The detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .task(let id)?:
            if let task = designTasks.first(where: { $0.id == id }) {
                switch task.kind {
                case .workflow: WorkflowSummary(select: { selection = .agent($0) })
                case .agent: AgentSummary(title: task.name, kind: "Explore", status: task.status, elapsed: task.elapsed)
                case .command: CommandSummary(task: task)
                }
            }
        case .phase(let id)?:
            if let phase = designPhases.first(where: { $0.id == id }) { PhaseSummary(phase: phase) }
        case .agent(let id)?:
            if let agent = designAllAgents.first(where: { $0.id == id }) {
                AgentSummary(title: agent.label, kind: "Review the diff for correctness", status: agent.status, elapsed: Int(agent.end - agent.start))
            }
        case nil:
            ContentUnavailableView("No Task Selected", systemImage: "square.stack.3d.up")
        }
    }
}

/// A row: the sidebar's dot on the title's line, a gray line under it, as the chat list has them.
private struct TaskLabel: View {
    let title: String
    let subtitle: String
    let state: ChatState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: ChatStatusDot.spacing) {
                // An agent's dot keeps still: a phase of running agents would be a wall of pulses.
                if compact, state == .working {
                    Circle().fill(.blue).frame(width: ChatStatusDot.size, height: ChatStatusDot.size)
                        .accessibilityLabel("Working")
                } else {
                    ChatStatusDot(state: state)
                }
                Text(title).lineLimit(compact ? 1 : 2)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, ChatStatusDot.gutter)
        }
        .help(title)
        .accessibilityElement(children: .combine)
    }
}

/// A detail's title and its actions, over the content, which scrolls under it.
private struct DetailBar<Actions: View>: View {
    let title: String
    let subtitle: String
    var monospaced = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(monospaced ? .headline.monospaced() : .headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack { actions }.buttonStyle(.bordered).fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct WorkflowSummary: View {
    let select: (String) -> Void

    var body: some View {
        Form {
            Section {
                // Agents done of those started so far: the script may start more.
                LabeledContent("Agents", value: counts(designAllAgents))
                LabeledContent("Phase", value: "Verify, 3 of 4")
                LabeledContent("Elapsed", value: "3m 02s")
                LabeledContent("Tokens", value: "412K")
            }
            Section("Phases") {
                ForEach(designPhases) { phase in
                    LabeledContent(phase.title, value: counts(phase.agents))
                }
            }
            Section("Needs Attention") {
                ForEach(designAllAgents.filter { $0.status == .failed }) { agent in
                    Button { select(agent.id) } label: {
                        LabeledContent(agent.label, value: agent.doing)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Log") {
                ForEach(Array(designLog.suffix(3).enumerated()), id: \.offset) { _, line in
                    LabeledContent(line.time) { Text(line.text).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .top) {
            DetailBar(title: "Review the diff for correctness", subtitle: "Workflow, running in the background") {
                Button("Show in Chat") {}
                Button("Stop Workflow", role: .destructive) {}
            }
        }
    }
}

private struct PhaseSummary: View {
    let phase: DesignPhase

    var body: some View {
        let running = phase.agents.filter { $0.status == .running }.count
        Form {
            Section {
                // A phase's agents are known once it starts: its progress is real.
                ProgressView(value: Double(phase.done), total: Double(phase.agents.count)) {
                    Text("Agents")
                } currentValueLabel: {
                    Text(counts(phase.agents))
                }
                LabeledContent("Step", value: phase.detail)
                LabeledContent("Tokens", value: "\(phase.agents.reduce(0) { $0 + $1.tokens } / 1000)K")
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .top) {
            DetailBar(title: phase.title, subtitle: "Phase of Review the diff for correctness") {
                Button("Stop Phase", role: .destructive) {}.disabled(running == 0)
            }
        }
    }
}

private struct AgentSummary: View {
    let title: String
    let kind: String
    let status: DesignStatus
    let elapsed: Int
    @State private var promptOpen = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: status == .running ? "Running in the background" : status.label)
                LabeledContent("Elapsed", value: duration(elapsed))
                LabeledContent("Model", value: "Sonnet")
                LabeledContent("Tool Calls", value: "18")
                LabeledContent("Tokens", value: "64K")
            }
            Section {
                DisclosureGroup("Prompt", isExpanded: $promptOpen) {
                    Text("Find every SwiftUI view in SundownUI and list which read `thread.items`.")
                        .textSelection(.enabled)
                }
            }
            Section("Activity") {
                DisclosureGroup("Searched code and read 6 files") {
                    Text("rg -n 'thread.items' SundownUI").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                Text("Most views read `rows`, not `items`. Two exceptions so far: `TranscriptFind` builds its search text from items, and `ThreadView` reads the last item for the Thinking line.")
                    .textSelection(.enabled)
                if status == .running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading ToolCallView.swift").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .top) {
            DetailBar(title: title, subtitle: kind) {
                Button("Show in Chat") {}
                if status == .running {
                    Button("Stop Task", role: .destructive) {}
                }
            }
        }
    }
}

private struct CommandSummary: View {
    let task: DesignTask

    private var output: String {
        task.status == .failed ? """
        $ xcodebuild -scheme Sundown build
        Resolve Package Graph
        Building for debugging...
        MarkdownText.swift:58:9: error: cannot find 'setText' in scope
        ** BUILD FAILED **
        """ : """
        $ swift test --package-path SundownKit
        Building for debugging...
        [42/88] Compiling SundownUI MarkdownText.swift
        Test Suite 'MarkdownTextTests' started
        ✔ Test copyIsPlainText() passed (0.036 seconds)
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Status", value: task.status == .failed ? "Failed, exit code 65" : "Running in the background")
                LabeledContent("Elapsed", value: duration(task.elapsed))
                LabeledContent("Directory", value: "~/Code/tether-app")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(output)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityTextContentType(.console)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            .background(.fill.quinary, in: .rect(cornerRadius: 10))
            .padding([.horizontal, .bottom], 20)
        }
        .safeAreaBar(edge: .top) {
            DetailBar(title: task.name, subtitle: "Command", monospaced: true) {
                Button("Copy Output") {}
                if task.status == .running { Button("Stop", role: .destructive) {} }
            }
        }
    }
}
#endif

#if DEBUG
// MARK: - 1, quiet: each thing said once, in words

private struct QuietSidebarDetail: View {
    @State private var selection: String? = "w"

    var body: some View {
        HSplitView {
            // A source list, as Xcode's navigators: no bands under its headers, no rules between rows.
            List(selection: $selection) {
                Section("Running") { ForEach(designTasks.filter { $0.status == .running }) { row($0) } }
                Section("Finished") { ForEach(designTasks.filter { $0.status != .running }) { row($0) } }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
            Group {
                if let task = designTasks.first(where: { $0.id == selection }) {
                    switch task.kind {
                    case .workflow: QuietWorkflow()
                    case .agent: QuietAgent(task: task)
                    case .command: QuietCommand(task: task)
                    }
                } else {
                    ContentUnavailableView("No Task Selected", systemImage: "square.stack.3d.up")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The name, and one word for where it stands.
    private func row(_ task: DesignTask) -> some View {
        HStack {
            Text(task.name).lineLimit(1)
            Spacer(minLength: 12)
            Text(word(task)).foregroundStyle(.secondary)
        }
        .help(task.name)
        .tag(task.id)
    }

    private func word(_ task: DesignTask) -> String {
        switch task.status {
        case .running: return duration(task.elapsed)
        case .failed: return "Failed"
        case .skipped: return "Stopped"
        default: return "Done"
        }
    }
}

/// One spacing scale: within a pair, between lines, between sections.
private enum QuietSpacing {
    static let pair: CGFloat = 4
    static let line: CGFloat = 8
    static let section: CGFloat = 20
}

/// Every detail starts the same: the title, the one sentence that says how it's going, its actions.
private struct QuietHeader<Actions: View>: View {
    let title: String
    let status: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: QuietSpacing.pair) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3).fontWeight(.semibold)
                Spacer(minLength: 12)
                HStack { actions }.fixedSize()
            }
            Text(status).foregroundStyle(.secondary)
        }
    }
}

/// A detail's body: one scroll, the window's standard margins, a readable width.
private struct QuietPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QuietSpacing.section) { content }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scenePadding([.horizontal, .bottom])
                .padding(.top, QuietSpacing.line)
        }
    }
}

private struct QuietWorkflow: View {
    @State private var open: String?
    @State private var agent: DesignAgent?

    var body: some View {
        if let agent {
            QuietAgent(agent: agent, workflow: "Review the diff for correctness") { self.agent = nil }
        } else {
            page
        }
    }

    private var page: some View {
        QuietPage {
            QuietHeader(title: "Review the diff for correctness", status: "Verifying findings · 3m 02s") {
                Button("Show in Chat") {}
                Button("Stop") {}
            }
            // One grid, so every phase's bar starts and ends at the same place and every count ends
            // on the same right edge as the buttons above.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: QuietSpacing.line) {
                ForEach(designPhases) { phase in
                    if phase.id != designPhases.first?.id { Divider() }
                    phaseRow(phase)
                    if open == phase.id { agents(phase) }
                }
            }
            VStack(alignment: .leading, spacing: QuietSpacing.line) {
                Text("Log").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(designLog.suffix(4).enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                }
            }
        }
    }

    private func phaseRow(_ phase: DesignPhase) -> some View {
        let failed = phase.agents.filter { $0.status == .failed }.count
        let running = phase.done < phase.agents.count && (phase.done > 0 || phase.agents.contains { $0.status == .running })
        let isOpen = open == phase.id
        return GridRow {
            Button {
                open = isOpen ? nil : phase.id
            } label: {
                Label(phase.title, systemImage: isOpen ? "chevron.down" : "chevron.right")
                    .labelStyle(PhaseLabelStyle())
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            // Only the phase under way has a bar: a finished one says Done, one to come Waiting.
            Group {
                if running {
                    ProgressView(value: Double(phase.done), total: Double(phase.agents.count))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .gridColumnAlignment(.leading)
            Text(phaseCount(phase, failed: failed))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .gridColumnAlignment(.trailing)
        }
    }

    /// An opened phase: what needs a look, failed then running, under its name.
    private func agents(_ phase: DesignPhase) -> some View {
        GridRow {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: QuietSpacing.line) {
                ForEach(phase.agents.filter { $0.status == .failed } + phase.agents.filter { $0.status == .running }) { agent in
                    GridRow {
                        Button(String(agent.label.drop { $0 != " " }.dropFirst())) { self.agent = agent }
                            .buttonStyle(.link)
                        Text(agent.status == .failed ? "Failed: \(agent.doing)" : agent.doing).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 16) // past the chevron, under the phase's name
            .gridCellColumns(3)
        }
    }

    private func phaseCount(_ phase: DesignPhase, failed: Int) -> String {
        if phase.done == phase.agents.count { return failed > 0 ? "Done, \(failed) failed" : "Done" }
        if phase.done == 0, !phase.agents.contains(where: { $0.status == .running }) { return "Waiting" }
        return "\(phase.done) of \(phase.agents.count)" + (failed > 0 ? ", \(failed) failed" : "")
    }
}

/// The disclosure chevron before the phase's name, small and gray, as a disclosure's own.
private struct PhaseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
            configuration.title
        }
    }
}

/// An agent's run is a transcript: its prompt, its calls, its replies. So its detail is the chat's own
/// transcript view, read-only, under a header that says what it is and how it's going.
private struct QuietAgent: View {
    let title: String
    let status: String
    let running: Bool
    let thread: ThreadModel
    /// Back to the workflow the agent belongs to, when it's one of its agents.
    var back: (label: String, action: () -> Void)?

    init(task: DesignTask) {
        title = task.name
        running = task.status == .running
        status = running ? "Running in the background · \(duration(task.elapsed))" : "Done · \(duration(task.elapsed))"
        thread = AgentRuns.run(id: task.id, prompt: "Find every SwiftUI view in SundownUI and list which read `thread.items`.", running: running)
    }

    init(agent: DesignAgent, workflow: String, back: @escaping () -> Void) {
        title = String(agent.label.drop { $0 != " " }.dropFirst()).capitalized
        running = agent.status == .running
        status = switch agent.status {
        case .running: "Running · \(duration(Int(agent.end - agent.start)))"
        case .failed: "Failed: \(agent.doing)"
        default: "Done · \(agent.doing)"
        }
        thread = AgentRuns.run(id: agent.id, prompt: "Check the finding for \(agent.label) and try to refute it. Say whether it's real, with the line that proves it.",
                               running: running, failed: agent.status == .failed)
        self.back = (workflow, back)
    }

    var body: some View {
        TranscriptView(thread: thread, connection: nil)
            .safeAreaBar(edge: .top) {
                VStack(alignment: .leading, spacing: QuietSpacing.line) {
                    if let back {
                        Button(back.label, systemImage: "chevron.left", action: back.action)
                            .buttonStyle(.link)
                    }
                    QuietHeader(title: title, status: status) {
                        Button("Show in Chat") {}
                        if running { Button("Stop") {} }
                    }
                }
                .scenePadding(.horizontal)
                .padding(.vertical, QuietSpacing.line)
            }
    }
}

/// Sample runs for the agents, made once each: a model is never made in a body.
@MainActor
private enum AgentRuns {
    private static var made: [String: ThreadModel] = [:]

    static func run(id: String, prompt: String, running: Bool, failed: Bool = false) -> ThreadModel {
        if let thread = made[id] { return thread }
        let root = "/Users/hayden/Code/tether-app/SundownKit/Sources/SundownUI/"
        var items: [Item] = [
            .sampleUserMessage(prompt, secondsAgo: 100),
            .sampleToolCall(name: "Grep", kind: .grep, input: ["pattern": "thread\\.items", "path": .string(root)],
                            outputText: "Thread/TranscriptFind.swift:88\nThread/ThreadView.swift:41", secondsAgo: 95),
            .sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "Thread/TranscriptFind.swift")], secondsAgo: 90),
            .sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "Thread/ThreadView.swift")], secondsAgo: 85),
            .sampleAgentMessage("Most views read `rows`, not `items`. Two exceptions so far:\n\n- `TranscriptFind` builds its search text from items.\n- `ThreadView` reads the last item for the Thinking line.", secondsAgo: 80),
        ]
        if failed {
            items.append(.sampleToolCall(name: "Bash", kind: .bash, input: ["command": "swift build --package-path SundownKit", "description": "Build SundownKit"],
                                         status: .failed, outputText: "Timed out after 120 s", secondsAgo: 40))
            items.append(.sampleNotice("Timed out", level: .warning, secondsAgo: 38))
        } else if running {
            items.append(.sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "ToolCallView.swift")],
                                         status: .running, secondsAgo: 5))
        } else {
            items.append(.sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string(root + "ToolCallView.swift")], secondsAgo: 60))
            items.append(.sampleAgentMessage("That's all of them: every other view reads `rows`.", secondsAgo: 50))
        }
        let thread = ThreadModel.sample(id: "agent-\(id)", status: running ? .running : .idle, items: items,
                                        turns: [.sample(status: running ? .inProgress : .completed, secondsAgo: 100)])
        made[id] = thread
        return thread
    }
}

private struct QuietCommand: View {
    let task: DesignTask

    var body: some View {
        QuietPage {
            QuietHeader(title: task.name,
                        status: task.status == .failed ? "Failed after \(duration(task.elapsed))" : "Running · \(duration(task.elapsed))") {
                Button("Copy Output") {}
                if task.status == .running { Button("Stop") {} }
            }
            // The output as text, on the page: a few lines aren't a pane, and lines don't wrap.
            ScrollView(.horizontal) { Text(task.status == .failed ? """
            Resolve Package Graph
            Building for debugging...
            MarkdownText.swift:58:9: error: cannot find 'setText' in scope
            ** BUILD FAILED **
            """ : """
            Building for debugging...
            [42/88] Compiling SundownUI MarkdownText.swift
            Test Suite 'MarkdownTextTests' started
            ✔ Test copyIsPlainText() passed (0.036 seconds)
            """)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize()
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
        }
    }
}
#endif
