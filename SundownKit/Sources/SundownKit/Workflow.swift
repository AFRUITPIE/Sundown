import Foundation
import TetherProtocol

// A Claude Code dynamic workflow ("ultracode"): a `Workflow` tool call whose script runs many
// agents in phases inside the CLI's workflow runner. The daemon says how it stands as tasks: the
// workflow's own (`TaskState.workflow`, its id the call's) and one per agent (`workflowAgent`,
// `<call id>/agent/<index>`), whose transcripts are `workflow/agentItems`.

extension Item.ToolCall {
    /// A dynamic workflow's launch, by the tool's name.
    public var isWorkflow: Bool { name == "Workflow" }

    /// A Workflow call's script, when it was sent inline (not run from a saved file).
    public var workflowScript: String? {
        guard isWorkflow, let script = input["script"]?.stringValue, !script.isEmpty else { return nil }
        return script
    }

    /// A workflow agent's last call, which hands its result back to the script (its input is the
    /// result, as JSON): what the agent returned, not something it did.
    public var isStructuredOutput: Bool { name == "StructuredOutput" }

    /// A Workflow call's name from what the call itself says, for a call the daemon has told of no
    /// run for yet: a named workflow, else the saved script's file (`<name>-<runId>.js`).
    public var workflowCallName: String? {
        if let name = input["name"]?.stringValue, !name.isEmpty { return name }
        guard let path = input["scriptPath"]?.stringValue, !path.isEmpty else { return nil }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return file.replacingOccurrences(of: #"-wf_[A-Za-z0-9_-]+$"#, with: "", options: .regularExpression)
    }
}

extension TaskState {
    /// Still going: running, or waiting to start.
    public var isGoing: Bool { status == .running || status == .waiting }

    /// Sent to the background, and still going there.
    public var isInBackground: Bool { backgrounded == true && isGoing }
}
