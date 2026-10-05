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
