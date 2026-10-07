import Testing
import SundownKit
import TetherProtocol
@testable import SundownUI

@Suite
struct ToolCallTextTests {
    private func call(_ kind: ToolKind, _ input: JSONValue, status: ToolStatus = .completed, output: String? = nil,
                      name: String = "Tool") -> Item.ToolCall {
        .sample(id: "c", name: name, kind: kind, input: input, status: status, outputText: output, secondsAgo: 1)
    }

    @Test func aLineReadsAsWhatTheCallDid() {
        let read = call(.fileRead, ["file_path": "/Users/me/Code/app/RootView.swift"])
        #expect(ToolCallText.verb(read) == "Read")
        #expect(ToolCallText.object(read) == "RootView.swift")
        #expect(ToolCallText.fullObject(read)?.hasSuffix("app/RootView.swift") == true)

        let running = call(.bash, ["command": "swift build\necho done", "description": "Build"], status: .running)
        #expect(ToolCallText.verb(running) == "Running a command")
        #expect(ToolCallText.object(running) == "")
        #expect(ToolCallText.fullObject(running) == "Build")

        let denied = call(.fileEdit, ["file_path": "/a/B.swift"], status: .denied)
        #expect(ToolCallText.verb(denied) == "Edit")
        #expect(ToolCallText.reason(denied) == "Denied")
    }

    /// A failed call says why with the first line of its error, without the CLI's tag around it.
    @Test func aFailureGivesItsFirstLine() {
        let failed = call(.bash, ["command": "make"], status: .failed,
                          output: "\n<tool_use_error>error: no such target</tool_use_error>\nmore")
        #expect(ToolCallText.reason(failed) == "error: no such target")
        #expect(ToolCallText.reason(call(.bash, ["command": "make"], status: .failed)) == "Failed")
        #expect(ToolCallText.reason(call(.bash, ["command": "make"])) == nil)
    }

    /// A workflow is called by its script's name, in its run's tense: its call comes back at once.
    @Test func aWorkflowReadsAsItsRun() {
        let script = "export const meta = { name: 'review-diff', description: 'Review', phases: [] }"
        let workflow = call(.other, ["script": .string(script)], name: "Workflow")
        let running = WorkflowRun(call: workflow, task: .init(threadId: "t", seq: 1, event: "progress", taskId: "w",
                                                             toolUseId: "c", status: "running", data: ["task_type": "local_workflow"]))
        #expect(ToolCallText.verb(workflow, workflow: running) == "Running workflow")
        #expect(ToolCallText.object(workflow, workflow: running) == "review-diff")
        // Without its run, what the call says, never its script read here.
        #expect(ToolCallText.verb(workflow) == "Ran workflow")
        #expect(ToolCallText.verb(call(.other, ["script": .string(script)], status: .running, name: "Workflow")) == "Running workflow")
        #expect(ToolCallText.object(workflow) == "")
        #expect(ToolCallText.verb(call(.other, [:], status: .denied, name: "Workflow")) == "Run workflow")
        // By name or path when the script isn't sent.
        #expect(ToolCallText.object(call(.other, ["scriptPath": "/a/b/spec.js"], name: "Workflow")) == "spec")
        #expect(ToolCallText.object(call(.other, ["scriptPath": "/a/b/typo-check-wf_a2813ad9-faf.js"], name: "Workflow")) == "typo-check")
        #expect(ToolCallText.object(call(.other, ["name": "deep-research"], name: "Workflow")) == "deep-research")
        #expect(ToolCallText.summary([workflow]) == "Ran a workflow")
        #expect(ToolCallText.summary([workflow, workflow]) == "Ran 2 workflows")
    }

    /// A workflow agent's hand-back of its result reads as what it is, not a bare tool name.
    @Test func structuredOutputReadsAsTheAgentsResult() {
        let result = call(.other, ["findings": []], name: "StructuredOutput")
        #expect(ToolCallText.verb(result) == "Returned its result")
        #expect(ToolCallText.object(result) == "")
        #expect(ToolCallText.verb(call(.other, [:], status: .running, name: "StructuredOutput")) == "Returning its result")
        #expect(ToolCallText.summary([call(.fileRead, ["file_path": "/a/math.swift"]), result]) == "Read math.swift and returned its result")

        // Refused (its schema didn't fit) or denied, it didn't hand anything back.
        let refused = call(.other, ["findings": "none"], status: .failed, name: "StructuredOutput")
        #expect(ToolCallText.verb(refused) == "Couldn’t return its result")
        #expect(ToolCallText.verb(call(.other, [:], status: .denied, name: "StructuredOutput")) == "Couldn’t return its result")
        #expect(ToolCallText.summary([refused]) == "Couldn’t return its result")
        #expect(ToolCallText.summary([refused, result]) == "Couldn’t return its result and returned its result")
        #expect(ToolCallText.summary([refused, refused, result]) == "Couldn’t return its result 2 times and returned its result")
    }

    @Test func aRunSaysWhatItsCallsDidTogether() {
        let calls = [
            call(.fileRead, ["file_path": "/a/One.swift"]),
            call(.bash, ["command": "ls"]),
            call(.fileRead, ["file_path": "/a/Two.swift"]),
            call(.grep, ["pattern": "x"]),
            call(.bash, ["command": "pwd"]),
        ]
        #expect(ToolCallText.summary(calls) == "Read 2 files, ran 2 commands, and searched code")
        #expect(ToolCallText.summary([call(.fileEdit, ["file_path": "/a/One.swift"]),
                                      call(.fileEdit, ["file_path": "/a/One.swift"])]) == "Edited One.swift")
        #expect(ToolCallText.summary([call(.mcp, [:], name: "mcp__xcode__BuildProject")]) == "Used xcode")
        #expect(ToolCallText.summary([call(.subagent, ["description": "5 second timer"], name: "Agent"),
                                      call(.subagent, ["description": "10 second timer"], name: "Agent")]) == "Ran 2 agents")
    }
}
