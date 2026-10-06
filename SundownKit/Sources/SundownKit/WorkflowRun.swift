import Foundation
import TetherProtocol

// A Claude Code dynamic workflow ("ultracode"): a `Workflow` tool call whose script runs many
// agents in phases inside the CLI's workflow runner. Its agents are no tasks of their own and send
// nothing to the stream: what the app knows of them is the workflow task's progress snapshot (the
// daemon's `task/event.workflow`, or the CLI's raw `workflow_progress` from an older daemon) and,
// after a reload, `workflow/read`. Pure, so it's tested without a view.

extension Item.ToolCall {
    /// A dynamic workflow's launch: recognized by the tool's name, so older daemons' calls are too.
    public var isWorkflow: Bool { name == "Workflow" }
}

/// What a workflow script says of itself: `export const meta = { name, description, phases }`, a
/// plain literal the CLI requires at the top of every script.
public enum WorkflowScript {
    public struct Meta: Equatable, Sendable {
        public var name: String?
        public var description: String?
        public var phases: [Phase]

        public struct Phase: Equatable, Sendable {
            public var title: String
            public var detail: String?
        }
    }

    /// The script's `meta`, read tolerantly: single, double or backtick quotes, keys quoted or not,
    /// comments and trailing commas. Nil when the script has none, or it can't be read.
    public static func meta(_ script: String) -> Meta? {
        guard let start = script.range(of: #"export\s+const\s+meta\s*=\s*"#, options: .regularExpression) else { return nil }
        var parser = JSLiteralParser(Array(script[start.upperBound...].unicodeScalars.prefix(50_000)))
        guard case .object(let object)? = parser.value() else { return nil }
        let phases = (object["phases"]?.arrayValue ?? []).compactMap { phase -> Meta.Phase? in
            if let title = phase["title"]?.stringValue ?? phase["name"]?.stringValue {
                return Meta.Phase(title: title, detail: phase["detail"]?.stringValue ?? phase["description"]?.stringValue)
            }
            return phase.stringValue.map { Meta.Phase(title: $0, detail: nil) }
        }
        return Meta(name: object["name"]?.stringValue, description: object["description"]?.stringValue, phases: phases)
    }
}

/// A JavaScript object literal's value, as JSON: enough of the language for a `meta` block.
private struct JSLiteralParser {
    private let s: [Unicode.Scalar]
    private var i = 0

    init(_ scalars: [Unicode.Scalar]) { s = scalars }

    private var current: Unicode.Scalar? { i < s.count ? s[i] : nil }

    private mutating func skipSpace() {
        while let c = current {
            if c.properties.isWhitespace {
                i += 1
            } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while let c = current, c != "\n" { i += 1 }
            } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i = min(i + 2, s.count)
            } else {
                return
            }
        }
    }

    mutating func value() -> JSONValue? {
        skipSpace()
        guard let c = current else { return nil }
        switch c {
        case "{": return object()
        case "[": return array()
        case "\"", "'", "`": return string().map(JSONValue.string)
        default:
            let token = word()
            guard !token.isEmpty else { return nil }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null", "undefined": return .null
            default: return Double(token).map(JSONValue.number) ?? .string(token)
            }
        }
    }

    /// An identifier or a number, up to the next delimiter.
    private mutating func word() -> String {
        var out = String.UnicodeScalarView()
        while let c = current, !c.properties.isWhitespace, !",:}]){[(".unicodeScalars.contains(c) {
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private mutating func string() -> String? {
        guard let quote = current else { return nil }
        i += 1
        var out = String.UnicodeScalarView()
        while let c = current {
            i += 1
            if c == quote { return String(out) }
            if c == "\\", let next = current {
                i += 1
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "u":
                    let hex = String(String.UnicodeScalarView(s[i..<min(i + 4, s.count)]))
                    if hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.append(scalar)
                        i += 4
                    } else {
                        out.append(next)
                    }
                default: out.append(next)
                }
            } else {
                out.append(c)
            }
        }
        return nil
    }

    private mutating func object() -> JSONValue? {
        i += 1
        var out: [String: JSONValue] = [:]
        while true {
            skipSpace()
            guard let c = current else { return nil }
            if c == "}" { i += 1; return .object(out) }
            if c == "," { i += 1; continue }
            let key: String
            if c == "\"" || c == "'" || c == "`" {
                guard let k = string() else { return nil }
                key = k
            } else if c == "." {
                // A spread: not a literal, so nothing to read.
                while current == "." { i += 1 }
                _ = word()
                continue
            } else {
                key = word()
                guard !key.isEmpty else { return nil }
            }
            skipSpace()
            // Shorthand (`{ name }`) names a variable, which isn't a literal.
            guard current == ":" else { continue }
            i += 1
            guard let v = value() else { return nil }
            out[key] = v
        }
    }

    private mutating func array() -> JSONValue? {
        i += 1
        var out: [JSONValue] = []
        while true {
            skipSpace()
            guard let c = current else { return nil }
            if c == "]" { i += 1; return .array(out) }
            if c == "," { i += 1; continue }
            guard let v = value() else { return nil }
            out.append(v)
        }
    }
}

/// One workflow run as the app shows it: what it's called, how it stands, its phases and agents,
/// what it used, and what it returned. Built from the daemon's snapshot (`task/event.workflow`,
/// `workflow/read`), or from the CLI's raw `workflow_progress` an older daemon passes through, with
/// the task's and the call's own words filling in what's missing.
public struct WorkflowRun: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case running, completed, failed, stopped
        /// Read from history with nothing to say how it went.
        case unknown
    }

    public struct Phase: Equatable, Sendable {
        public var index: Int
        public var title: String
        public var detail: String?
    }

    public struct Agent: Equatable, Sendable, Identifiable {
        public enum State: Equatable, Sendable {
            case running, waiting, done, failed, stopped
        }

        public var index: Int
        public var label: String
        public var phaseIndex: Int?
        public var phaseTitle: String?
        public var agentId: String?
        public var model: String?
        public var state: State
        public var queuedAt: Double?
        public var startedAt: Double?
        public var durationMs: Double?
        public var tokens: Double?
        public var toolCalls: Int?
        public var lastProgressAt: Double?
        public var lastToolName: String?
        public var lastToolSummary: String?
        public var promptPreview: String?
        public var resultPreview: String?
        public var error: String?

        public var id: Int { index }
    }

    /// The tool call that launched it.
    public var toolUseId: String
    /// The CLI's task for it, while this client has heard of one: what Stop stops.
    public var taskId: String?
    public var runId: String?
    public var name: String?
    public var description: String?
    public var status: Status
    /// The latest agent event, "Phase: label".
    public var activity: String?
    public var phases: [Phase]
    public var agents: [Agent]
    public var totalTokens: Double?
    public var toolUses: Int?
    public var durationMs: Double?
    /// What the workflow returned, as text, once it has finished.
    public var result: String?
    /// The script's error, when it failed.
    public var error: String?

    public var isRunning: Bool { status == .running }

    /// The run of `call`, from what's known of it: the task's latest event (merged, so its data
    /// carries the last snapshot), a snapshot read with `workflow/read`, and the call itself.
    public init(call: Item.ToolCall, task: TaskEventNotification?, loaded: JSONValue? = nil,
                meta: WorkflowScript.Meta? = nil) {
        let data = task?.data ?? .null
        let snapshot = data["workflow"].flatMap { $0.objectValue == nil ? nil : $0 } ?? loaded
        let meta = meta ?? call.input["script"]?.stringValue.flatMap(WorkflowScript.meta)
        toolUseId = call.id
        taskId = task?.taskId ?? Self.taskID(fromLaunchText: call.outputText)
        runId = snapshot?["runId"]?.stringValue ?? call.output?["runId"]?.stringValue
            ?? Self.runID(fromLaunchText: call.outputText)
        name = snapshot?["name"]?.stringValue ?? data["workflow_name"]?.stringValue ?? call.output?["workflowName"]?.stringValue
            ?? meta?.name ?? call.input["name"]?.stringValue
            ?? call.input["scriptPath"]?.stringValue.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        description = snapshot?["description"]?.stringValue ?? task?.description ?? meta?.description
        activity = snapshot?["activity"]?.stringValue ?? data["workflow_activity"]?.stringValue
        totalTokens = snapshot?["totalTokens"]?.doubleValue ?? data["usage"]?["total_tokens"]?.doubleValue
        toolUses = (snapshot?["toolUses"]?.doubleValue ?? data["usage"]?["tool_uses"]?.doubleValue).map { Int($0) }
        durationMs = snapshot?["durationMs"]?.doubleValue ?? data["usage"]?["duration_ms"]?.doubleValue
        result = snapshot?["result"]?.stringValue
        error = snapshot?["error"]?.stringValue

        // How it stands: a settled task says so; else the snapshot; else the call, which comes back
        // at once (`async_launched`), so finishing says nothing of the workflow.
        if let task, !InspectorTaskEntry.isRunning(task) {
            status = Self.status(task.status ?? task.event)
        } else if task != nil {
            status = .running
        } else if let raw = snapshot?["status"]?.stringValue {
            status = Self.status(raw)
        } else {
            switch call.status {
            case .running, .pending: status = .running
            case .failed, .denied: status = .failed
            case .interrupted: status = .stopped
            default: status = .unknown
            }
        }

        // Phases: the snapshot's own, or the raw entries'; a withheld script's titles ("phase 2")
        // come from the script's meta, whose phases are numbered from 1 in order.
        var phases: [Phase] = []
        var agents: [Agent] = []
        if let snapshot {
            for p in snapshot["phases"]?.arrayValue ?? [] {
                guard let index = p["index"]?.doubleValue else { continue }
                phases.append(Phase(index: Int(index), title: p["title"]?.stringValue ?? "", detail: p["detail"]?.stringValue))
            }
            agents = (snapshot["agents"]?.arrayValue ?? []).compactMap(Self.agent)
        } else if let raw = data["workflow_progress"]?.arrayValue {
            for entry in raw {
                switch entry["type"]?.stringValue {
                case "workflow_phase":
                    guard let index = entry["index"]?.doubleValue else { continue }
                    phases.append(Phase(index: Int(index), title: entry["title"]?.stringValue ?? "", detail: nil))
                case "workflow_agent":
                    if let agent = Self.agent(entry) { agents.append(agent) }
                default: break
                }
            }
        }
        // Each index once, the last one said.
        phases = Dictionary(phases.map { ($0.index, $0) }, uniquingKeysWith: { _, b in b }).values.sorted { $0.index < $1.index }
        agents = Dictionary(agents.map { ($0.index, $0) }, uniquingKeysWith: { _, b in b }).values.sorted { $0.index < $1.index }
        for i in phases.indices {
            if let better = Self.metaTitle(phases[i].index, phases[i].title, meta) { phases[i].title = better }
            if phases[i].detail == nil, let m = meta, phases[i].index >= 1, phases[i].index <= m.phases.count {
                phases[i].detail = m.phases[phases[i].index - 1].detail
            }
        }
        // Phases named only by their agents, as a phase that's announced late is.
        for agent in agents {
            if let index = agent.phaseIndex, !phases.contains(where: { $0.index == index }) {
                phases.append(Phase(index: index, title: agent.phaseTitle ?? "", detail: nil))
            }
        }
        phases.sort { $0.index < $1.index }
        let settled = status != .running
        for i in agents.indices {
            let index = agents[i].phaseIndex
            if let index, let phase = phases.first(where: { $0.index == index }), !phase.title.isEmpty,
               agents[i].phaseTitle == nil || Self.isPlaceholder(agents[i].phaseTitle!) {
                agents[i].phaseTitle = phase.title
            } else if let index, let title = agents[i].phaseTitle, let better = Self.metaTitle(index, title, meta) {
                agents[i].phaseTitle = better
            }
            // An agent still going in a workflow that has ended was stopped with it.
            if settled, agents[i].state == .running || agents[i].state == .waiting { agents[i].state = .stopped }
        }
        self.phases = phases.filter { phase in !phase.title.isEmpty || agents.contains { $0.phaseIndex == phase.index } }
        self.agents = agents
    }

    /// A snapshot read with `workflow/read`, with no call to hand: a reload's, before its call is.
    public init?(toolUseId: String, snapshot: JSONValue) {
        guard snapshot.objectValue != nil else { return nil }
        self.init(call: .init(id: toolUseId, createdAt: 0, name: "Workflow", kind: .other, input: [:], status: .completed),
                  task: nil, loaded: snapshot)
    }

    private static func status(_ raw: String) -> Status {
        let s = raw.lowercased()
        if s.contains("fail") || s.contains("error") { return .failed }
        if s.contains("stop") || s.contains("kill") || s.contains("interrupt") || s.contains("cancel") || s.contains("pause") { return .stopped }
        if s.contains("complete") || s.contains("done") || s.contains("finish") || s == "notification" { return .completed }
        if s.contains("run") || s.contains("start") || s.contains("progress") || s.contains("pending") { return .running }
        return .unknown
    }

    /// "phase 2", which is all the CLI says of a phase when it withholds the script.
    private static func isPlaceholder(_ title: String) -> Bool {
        title.range(of: #"^phase \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil || title.isEmpty
    }

    private static func metaTitle(_ index: Int, _ title: String, _ meta: WorkflowScript.Meta?) -> String? {
        guard isPlaceholder(title), let meta, index >= 1, index <= meta.phases.count else { return nil }
        return meta.phases[index - 1].title
    }

    /// One agent, from the snapshot's normalized shape or the CLI's raw `workflow_agent` entry.
    private static func agent(_ v: JSONValue) -> Agent? {
        guard let index = v["index"]?.doubleValue else { return nil }
        let raw = (v["state"]?.stringValue ?? "").lowercased()
        let error = v["error"]?.stringValue
        let queuedAt = v["queuedAt"]?.doubleValue
        let startedAt = v["startedAt"]?.doubleValue
        let state: Agent.State
        switch raw {
        case "done", "completed": state = .done
        case "skipped", "stopped", "killed": state = .stopped
        case "error", "failed":
            state = v["skipped"]?.boolValue == true || error == "skipped by user" ? .stopped : .failed
        case "queued", "waiting", "pending": state = .waiting
        default:
            // "start" before it has a slot is waiting, as the CLI counts it.
            state = raw == "start" && queuedAt != nil && startedAt == nil ? .waiting : .running
        }
        return Agent(
            index: Int(index), label: v["label"]?.stringValue ?? "Agent \(Int(index))",
            phaseIndex: v["phaseIndex"]?.doubleValue.map { Int($0) }, phaseTitle: v["phaseTitle"]?.stringValue,
            agentId: v["agentId"]?.stringValue, model: v["model"]?.stringValue, state: state,
            queuedAt: queuedAt, startedAt: startedAt, durationMs: v["durationMs"]?.doubleValue,
            tokens: v["tokens"]?.doubleValue, toolCalls: v["toolCalls"]?.doubleValue.map { Int($0) },
            lastProgressAt: v["lastProgressAt"]?.doubleValue,
            lastToolName: v["lastToolName"]?.stringValue, lastToolSummary: v["lastToolSummary"]?.stringValue,
            promptPreview: v["promptPreview"]?.stringValue, resultPreview: v["resultPreview"]?.stringValue,
            error: state == .stopped && error == "skipped by user" ? nil : error)
    }

    /// The run's id in the launch receipt the call returns ("Run ID: …"), which history keeps too.
    public static func runID(fromLaunchText text: String?) -> String? {
        firstMatch(#"(?m)^\s*Run ID:\s*(\S+)"#, in: text)
    }

    /// The task's id in the launch receipt, for Stop after a reload.
    public static func taskID(fromLaunchText text: String?) -> String? {
        firstMatch(#"Task ID:\s*(\S+)"#, in: text)
    }

    private static func firstMatch(_ pattern: String, in text: String?) -> String? {
        guard let text, let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    }

    // MARK: words

    public var doneCount: Int { agents.count { $0.state == .done } }

    /// The phase being worked on: the latest running agent's, else the latest agent's.
    public var currentPhase: Phase? {
        let agent = agents.last { $0.state == .running } ?? agents.last
        guard let index = agent?.phaseIndex else { return nil }
        return phases.first { $0.index == index }
    }

    /// How far it has got, while it runs: "Verify: 3 of 4 agents done", or "Starting" before any
    /// agent.
    public var progressText: String {
        guard !agents.isEmpty else { return "Starting" }
        let count = Self.inflected("\(doneCount) of ^[\(agents.count) agent](inflect: true) done")
        guard phases.count > 1, let phase = currentPhase, !phase.title.isEmpty else { return count }
        return "\(phase.title): \(count)"
    }

    /// How a phase stands, in words: "List: 3 agents, done", "Verify: running".
    public func phaseSummary(_ phase: Phase) -> String {
        let agents = self.agents.filter { $0.phaseIndex == phase.index }
        let title = phase.title.isEmpty ? "Phase \(phase.index)" : phase.title
        let state: String
        if agents.contains(where: { $0.state == .running }) {
            state = "running"
        } else if agents.contains(where: { $0.state == .waiting }) || agents.isEmpty {
            state = status == .running ? "waiting" : "not run"
        } else if agents.contains(where: { $0.state == .failed }) {
            state = "failed"
        } else if agents.contains(where: { $0.state == .stopped }) {
            state = "stopped"
        } else {
            state = "done"
        }
        guard !agents.isEmpty, state != "running" else { return "\(title): \(state)" }
        return "\(title): " + Self.inflected("^[\(agents.count) agent](inflect: true), \(state)")
    }

    /// What it used, in words: "4 agents · 98,951 tokens · 23 tool uses · 43s".
    public var usageText: String {
        var parts: [String] = []
        if !agents.isEmpty { parts.append(Self.inflected("^[\(agents.count) agent](inflect: true)")) }
        if let tokens = totalTokens, tokens > 0 {
            parts.append(Self.inflected("^[\(Int(tokens)) token](inflect: true)"))
        }
        if let uses = toolUses, uses > 0 { parts.append(Self.inflected("^[\(uses) tool use](inflect: true)")) }
        if let ms = durationMs, ms > 0 { parts.append(Self.duration(ms / 1000)) }
        return parts.joined(separator: " · ")
    }

    /// A finished run's caption on its row: how many agents it ran and how long it took.
    public var finishedCaption: String {
        var parts: [String] = []
        if !agents.isEmpty { parts.append(Self.inflected("^[\(agents.count) agent](inflect: true)")) }
        if let ms = durationMs, ms > 0 { parts.append(Self.duration(ms / 1000)) }
        return parts.joined(separator: " · ")
    }

    /// "42s", "3m 12s": the two largest units.
    public static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    private static func inflected(_ text: String.LocalizationValue) -> String {
        String(AttributedString(localized: text).characters)
    }
}

/// The daemon's workflow methods. Declared here rather than taken from the protocol package, so
/// the app reads workflows from a daemon that has them while it builds against a package that
/// doesn't; a daemon without them answers "method not found", and they aren't asked again.
public enum WorkflowMethods {
    /// A run's snapshot, from the live thread, the CLI's run record or its journal.
    public enum Read: TetherMethod {
        public static let name = "workflow/read"
        public struct Params: Encodable, Sendable {
            public let threadId: String
            public let runId: String
        }
        public struct Result: Decodable, Sendable {
            public let workflow: JSONValue?
        }
    }

    /// One agent's transcript, itemized as history is.
    public enum AgentItems: TetherMethod {
        public static let name = "workflow/agentItems"
        public struct Params: Encodable, Sendable {
            public let threadId: String
            public let runId: String
            public let agentId: String
        }
        public struct Result: Decodable, Sendable {
            public let items: [Item]
        }
    }
}
