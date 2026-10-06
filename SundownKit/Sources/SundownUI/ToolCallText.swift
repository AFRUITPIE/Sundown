import Foundation
import SundownKit
import TetherProtocol

/// The words a tool call's line reads as: a verb in the tense its status calls for ("Reading",
/// "Read", "Read" for a denied call too — its reason line says it didn't happen), then what it
/// acted on. And for a run of finished calls, one line that says what they did together:
/// "Read 3 files, searched code, and ran 2 commands". Pure, so it's tested without a view.
enum ToolCallText {
    /// The verb, before what the call acted on. A workflow's tense is its run's: its call comes
    /// back as soon as the run has started.
    static func verb(_ call: Item.ToolCall, workflow: WorkflowRun? = nil) -> String {
        if call.isWorkflow {
            let run = workflow ?? WorkflowRun(call: call, task: nil)
            if call.status == .denied { return "Run workflow" }
            return run.isRunning ? "Running workflow" : "Ran workflow"
        }
        let running = call.status == .running || call.status == .pending
        switch call.kind {
        // Just that it ran: the command is in the help tag and the opened row, not on the line.
        case .bash: return running ? "Running a command" : call.status == .denied ? "Run a command" : "Ran a command"
        case .fileRead: return running ? "Reading" : "Read"
        case .fileWrite: return running ? "Writing" : call.status == .denied ? "Write" : "Wrote"
        case .fileEdit, .notebookEdit: return running ? "Editing" : call.status == .denied ? "Edit" : "Edited"
        case .grep, .glob: return running ? "Searching for" : call.status == .denied ? "Search for" : "Searched for"
        case .webSearch: return running ? "Searching the web for" : call.status == .denied ? "Search the web for" : "Searched the web for"
        case .webFetch: return running ? "Fetching" : call.status == .denied ? "Fetch" : "Fetched"
        case .skill: return running ? "Using" : call.status == .denied ? "Use" : "Used"
        case .subagent: return running ? "Running an agent:" : call.status == .denied ? "Run an agent:" : "Ran an agent:"
        case .monitor: return running ? "Watching" : "Watched"
        case .todoWrite: return "Todos"
        case .mcp: return mcpName(call)
        default: return call.name
        }
    }

    /// What the call acted on: a file's name (its path is in the help tag and the detail), a
    /// search pattern, a URL's host and path. Nothing for a command: a shell line is more than a
    /// reader wants on every row.
    static func object(_ call: Item.ToolCall, workflow: WorkflowRun? = nil) -> String {
        if call.kind == .bash { return "" }
        if call.isWorkflow { return (workflow ?? WorkflowRun(call: call, task: nil)).name ?? "" }
        if let summary = call.summary { return summary }
        let input = call.input
        switch call.kind {
        case .fileRead, .fileWrite, .fileEdit, .notebookEdit:
            return ((input.string("file_path") ?? input.string("notebook_path") ?? "") as NSString).lastPathComponent
        case .grep, .glob: return input.string("pattern").map { "“\($0)”" } ?? ""
        case .webSearch: return input.string("query").map { "“\($0)”" } ?? ""
        case .webFetch:
            guard let raw = input.string("url"), let url = URL(string: raw), let host = url.host() else {
                return input.string("url") ?? ""
            }
            return host + (url.path() == "/" ? "" : url.path())
        case .subagent: return input.string("description") ?? ""
        case .skill: return input.string("skill") ?? input.string("command") ?? ""
        case .monitor: return input.string("description") ?? ""
        default: return ""
        }
    }

    /// For a help tag: what a command is for, or the full path when `object` shortens it.
    static func fullObject(_ call: Item.ToolCall) -> String? {
        let input = call.input
        switch call.kind {
        case .bash: return input.string("description") ?? input.string("command")
        case .fileRead, .fileWrite, .fileEdit, .notebookEdit:
            return (input.string("file_path") ?? input.string("notebook_path"))?.abbreviatingHome
        case .webFetch: return input.string("url")
        default: return nil
        }
    }

    /// Why a call that went wrong did: the first line of its error, or that it was denied or stopped.
    static func reason(_ call: Item.ToolCall) -> String? {
        switch call.status {
        case .denied: return "Denied"
        case .interrupted: return "Stopped"
        case .failed:
            let line = (call.outputText ?? "")
                .split(whereSeparator: \.isNewline)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            // The CLI wraps a failed call's output in a tag of its own.
            return line.map { $0.replacingOccurrences(of: "<tool_use_error>", with: "").replacingOccurrences(of: "</tool_use_error>", with: "") } ?? "Failed"
        default: return nil
        }
    }

    /// A run of finished calls as one line, the kinds in the order they first appear.
    static func summary(_ calls: [Item.ToolCall]) -> String {
        var order: [String] = []
        var groups: [String: [Item.ToolCall]] = [:]
        for call in calls {
            let key = groupKey(call)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(call)
        }
        let phrases = order.map { phrase(for: groups[$0]!) }
        guard !phrases.isEmpty else { return "" }
        let joined = ListFormatter.localizedString(byJoining: phrases)
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func groupKey(_ call: Item.ToolCall) -> String {
        switch call.kind {
        case .fileEdit, .notebookEdit: return "edit"
        case .grep, .glob: return "search"
        case .mcp: return "mcp:" + (call.mcpServer ?? mcpServerName(call) ?? "")
        default: return call.isWorkflow ? "workflow" : call.kind.rawValue
        }
    }

    /// One kind's share of the line, lower case: the list is capitalized as a whole.
    private static func phrase(for calls: [Item.ToolCall]) -> String {
        let n = calls.count
        let first = calls[0]
        let files = Set(calls.map { object($0) }).count
        if first.isWorkflow { return n == 1 ? "ran a workflow" : "ran \(n) workflows" }
        switch first.kind {
        case .bash: return n == 1 ? "ran a command" : "ran \(n) commands"
        case .fileRead: return files == 1 ? "read \(object(first))" : "read \(files) files"
        case .fileWrite: return files == 1 ? "wrote \(object(first))" : "wrote \(files) files"
        case .fileEdit, .notebookEdit: return files == 1 ? "edited \(object(first))" : "edited \(files) files"
        case .grep, .glob: return "searched code"
        case .webSearch: return "searched the web"
        case .webFetch: return n == 1 ? "fetched a page" : "fetched \(n) pages"
        case .skill: return n == 1 ? "used a skill" : "used \(n) skills"
        case .subagent: return n == 1 ? "ran an agent" : "ran \(n) agents"
        case .mcp: return "used " + (first.mcpServer ?? mcpServerName(first) ?? "an MCP server")
        default: return n == 1 ? "used \(first.name)" : "used \(first.name) \(n) times"
        }
    }

    /// `mcp__server__tool` as "server · tool".
    private static func mcpName(_ call: Item.ToolCall) -> String {
        let parts = call.name.split(separator: "_", omittingEmptySubsequences: true)
        return parts.count >= 3 ? "\(parts[1]) · \(parts[2...].joined(separator: "_"))" : call.name
    }

    private static func mcpServerName(_ call: Item.ToolCall) -> String? {
        let parts = call.name.split(separator: "_", omittingEmptySubsequences: true)
        return parts.count >= 3 ? String(parts[1]) : nil
    }
}
