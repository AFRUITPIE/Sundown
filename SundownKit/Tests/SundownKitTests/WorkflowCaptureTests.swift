import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// A real dynamic workflow, as Claude Code 2.1.291 ran it: "typo-check", six Haiku agents in three
/// phases (Scan, Review, Verify), captured with `TETHER_DEBUG_TASKS=1` from a daemon that passed
/// the CLI's task messages through (`Fixtures/workflow-typo-check-events.jsonl`, home paths
/// scrubbed), the Workflow call and its launch receipt from the session's transcript, and one
/// agent's transcript as the daemon itemizes it. What it showed: agents' states are only `start`,
/// `progress` and `done`; `workflow_progress` comes on some progress events only, the whole list
/// each time; and the task settles (`task_updated`, then `task_notification`) once the last agent's
/// `done` has been reported, or not at all.
@MainActor
@Suite
struct WorkflowCaptureTests {
    private let threadID = "dc2cc722"

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The CLI's task messages, in the order they came.
    private static func messages() throws -> [JSONValue] {
        let text = String(decoding: try fixture("workflow-typo-check-events", "jsonl"), as: UTF8.self)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    private struct Call: Decodable {
        let id: String
        let input: JSONValue
        let outputText: String
    }

    private func call() throws -> Item.ToolCall {
        let c = try JSONDecoder().decode(Call.self, from: try Self.fixture("workflow-typo-check-call", "json"))
        return .init(id: c.id, createdAt: 1_791_322_745_000, name: "Workflow", kind: .other, input: c.input,
                     status: .completed, outputText: c.outputText)
    }

    /// A task message as a daemon that passes it through sends it: its subtype as the event, its
    /// fields as they are, the whole message as data.
    private func event(_ m: JSONValue, seq: Int) -> TaskEventNotification {
        let subtype = m["subtype"]?.stringValue ?? ""
        return .init(threadId: threadID, seq: seq, event: String(subtype.dropFirst("task_".count)),
                     taskId: m["task_id"]?.stringValue ?? "", toolUseId: m["tool_use_id"]?.stringValue,
                     description: m["description"]?.stringValue,
                     status: m["status"]?.stringValue ?? m["patch"]?["status"]?.stringValue, data: m)
    }

    private func thread() throws -> (ThreadModel, Item.ToolCall) {
        let call = try call()
        let thread = ThreadModel(id: threadID)
        let prompt = Item.userMessage(.init(id: "p", createdAt: 1_791_322_740_000, content: [.text(.init(text: "ultracode: typo-check"))]))
        thread.loadHistory(items: [prompt, .toolCall(call)], turns: [], seq: 0)
        return (thread, call)
    }

    @Test func theLaunchReceiptNamesTheRun() throws {
        let call = try call()
        #expect(WorkflowRun.runID(fromLaunchText: call.outputText) == "wf_a2813ad9-faf")
        #expect(WorkflowRun.taskID(fromLaunchText: call.outputText) == "wsjxcgcst")
        #expect(WorkflowScript.meta(call.workflowScript ?? "")?.phases.map(\.title) == ["Scan", "Review", "Verify"])
    }

    @Test func theRunIsFollowedFromItsEvents() throws {
        let (thread, call) = try thread()
        let messages = try Self.messages()
        #expect(messages.count == 41)
        for (i, m) in messages.enumerated() {
            thread.apply(.taskEvent(event(m, seq: i + 1)))
            let run = try #require(thread.workflowRuns[call.id])
            #expect(run.name == "typo-check", "event \(i)")
            #expect(run.agents.allSatisfy { $0.phaseTitle != nil }, "event \(i)")
            // Two Review agents announced before they had a slot are waiting, not running.
            if i == 6 {
                #expect(run.agents.map(\.state) == [.done, .running, .waiting, .waiting])
                #expect(run.progressText == "Review: 1 of 4 agents done")
            }
            if i < 39 { #expect(run.isRunning, "event \(i)") }
        }
        let run = try #require(thread.workflowRuns[call.id])
        #expect(run.status == .completed)
        #expect(run.description == "List files, review each for typos/bugs, verify findings")
        #expect(run.phases.map(\.title) == ["Scan", "Review", "Verify"])
        #expect(run.agents.map(\.label) == ["list-files", "review:math.swift", "review:README.md", "review:notes.md", "verify-1", "verify-2"])
        #expect(run.agents.map(\.phaseTitle) == ["Scan", "Review", "Review", "Review", "Verify", "Verify"])
        #expect(run.agents.allSatisfy { $0.state == .done })
        #expect(run.finishedCaption == "6 agents · 32s")
        #expect(run.usageText == "6 agents · 77,475 tokens · 16 tool uses · 32s")
        #expect(thread.taskEntries.first?.workflow == run)
    }

    /// The run's progress is sent only now and then: when it settles before its last agent's
    /// `done` is heard, that agent finished with it, not stopped.
    @Test func aCompletedRunFinishesTheAgentsItLastHeardOfRunning() throws {
        let (thread, call) = try thread()
        let messages = try Self.messages()
        let last = try #require(messages.lastIndex { $0["workflow_progress"] != nil })
        for (i, m) in messages.enumerated() where i != last {
            thread.apply(.taskEvent(event(m, seq: i + 1)))
        }
        let run = try #require(thread.workflowRuns[call.id])
        #expect(run.status == .completed)
        #expect(run.agents.allSatisfy { $0.state == .done })
    }

    /// A daemon may say a workflow has finished at once, by a message of its own with a stable id,
    /// and fill in its result once it has it: one row, showing the latest.
    @Test func theFinishIsOneRowUpdatedInPlace() throws {
        let (thread, _) = try thread()
        func finish(_ text: String) -> Item {
            .userMessage(.init(id: "workflow-finish-wsjxcgcst", createdAt: 1_791_322_778_430, content: [.text(.init(text: text))],
                               synthetic: true, origin: "workflow", originName: "typo-check"))
        }
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 1, item: finish("Workflow completed"))))
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 2, item: finish(#"{"verified":[]}"#))))
        let rows = thread.rows(.summarized).filter { $0.id == "workflow-finish-wsjxcgcst" }
        #expect(rows.count == 1)
        guard case .item(.userMessage(let m))? = rows.first, case .text(let t)? = m.content.first else {
            Issue.record("no finish row"); return
        }
        #expect(t.text == #"{"verified":[]}"#)
    }

    // MARK: slow-check, as the daemon sends it

    /// A second real run in the same chat, slow-check, whose three Wait agents each ran `sleep 45`
    /// in the background: the notifications the daemon sends for it
    /// (`Fixtures/workflow-slow-check-notifications.jsonl`, made by the server's itemizer from its
    /// capture). The CLI's `<task-notification>` message never reaches the stream, so the finish is
    /// the daemon's from the task's event, with the run record's result; the agents' commands are
    /// tasks said to be theirs, and no line in the chat.
    private func slowCheck() throws -> ThreadModel {
        let text = String(decoding: try Self.fixture("workflow-slow-check-notifications", "jsonl"), as: UTF8.self)
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [], turns: [], seq: 0)
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            let message = try decoder.decode(JSONValue.self, from: Data(line.utf8))
            let method = try #require(message["method"]?.stringValue)
            let params = try JSONEncoder().encode(try #require(message["params"]))
            let n = RPCClient.carryingWorkflow(try ServerNotification(method: method, params: params, decoder: decoder),
                                               params: params, decoder: decoder)
            thread.apply(n)
        }
        return thread
    }

    @Test func slowChecksFinishIsARowBeforeTheReplyAnsweringIt() throws {
        let thread = try slowCheck()
        let rows = thread.rows(.summarized)
        let at = try #require(rows.firstIndex { $0.id == "workflow_wmcpqnf9b_finished" })
        guard case .item(.userMessage(let finish)) = rows[at], case .text(let t)? = finish.content.first else {
            Issue.record("no finish row"); return
        }
        #expect(finish.origin == "workflow")
        #expect(finish.originName == "slow-check")
        #expect(t.text.contains(#""report": "all waited""#))
        #expect(rows.indices.contains(at + 1) && rows[at + 1].id == "msg_011Cfmk8tuutNMNdJrxLtVJV:0")
        #expect(thread.turns.map(\.id).last == "turn_workflow_wmcpqnf9b_finished")
        #expect(!thread.topLevelItems.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func slowChecksAgentsCommandsAreTheirs() throws {
        let thread = try slowCheck()
        let call = "toolu_01Jby5Vz6jDDNapaZdT1BPdG"
        let run = try #require(thread.workflowRuns[call])
        #expect(run.status == .completed)
        let owned = ["burds59jn": "wait-1", "bugthm7m1": "wait-2", "b8r5g0sol": "wait-3", "bv2g61ik6": "wait-3"]
        for (taskId, label) in owned {
            let task = try #require(thread.taskEntries.first { $0.id == "task:\(taskId)" }?.task, "\(taskId)")
            #expect(task.ownedBySubagent == true, "\(taskId)")
            #expect(task.workflowToolUseId == call, "\(taskId)")
            #expect(run.agents.first { $0.agentId == task.workflowAgentId }?.label == label, "\(taskId)")
            #expect(task.status == "stopped", "\(taskId)")
            // Only the start said so in the CLI's own words; the notification's data didn't.
            #expect(task.data["owned_by_subagent"]?.boolValue == true, "\(taskId)")
        }
    }

    // MARK: an agent's transcript

    /// The agent's transcript as the daemon's `readAgentItems` serves it, its prompt unframed.
    private func agentItems() throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: try Self.fixture("workflow-typo-check-agent-items", "json"))
    }

    /// The same transcript as an older daemon served it, with the harness's framing.
    private func framedAgentItems() throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: try Self.fixture("workflow-typo-check-agent-items-framed", "json"))
    }

    private static let task = "Read /private/tmp/wf-scratch/math.swift (do not edit). Find typos and code bugs. Return findings with line numbers; empty list if none."

    private func prompts(_ items: [Item]) -> [String] {
        items.compactMap {
            guard case .userMessage(let m) = $0 else { return nil }
            return m.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined(separator: "\n")
        }
    }

    /// The agent's prompt is the script's task alone: the harness's framing and the person's
    /// relayed request go.
    @Test func anAgentsPromptIsItsTaskAlone() throws {
        // The daemon serves it unframed, and it's kept as it is.
        let served = try agentItems()
        #expect(prompts(served) == [Self.task])
        #expect(WorkflowAgentPrompt.unframed(served) == served)
        // An older daemon's, framed, reads the same.
        let raw = try framedAgentItems()
        #expect(prompts(raw).count == 2)
        let items = WorkflowAgentPrompt.unframed(raw)
        #expect(prompts(items) == [Self.task])
        #expect(items.count == raw.count - 1)
        #expect(WorkflowAgentPrompt.unframed(items) == items)
        // Both frames in one message, as a client that joins them would have it.
        let joined = prompts(raw).joined(separator: "\n\n")
        #expect(WorkflowAgentPrompt.unframed([.userMessage(.init(id: "j", createdAt: 0, content: [.text(.init(text: joined))]))])
            .flatMap { prompts([$0]) } == [Self.task])
    }

    @Test func aMultilineTaskIsDeindented() {
        let framed = "[Workflow harness — computed task] The computed task text follows:\n  Check these:\n    - one\n\n  - two"
        #expect(WorkflowAgentPrompt.unframed(framed) == "Check these:\n  - one\n\n- two")
        #expect(WorkflowAgentPrompt.unframed("Just a prompt") == nil)
        // A frame is the text's start, with its whole marker: one quoted inside a prompt, or one
        // without the marker, is the prompt's own words.
        let quoted = "Explain this:\n[Workflow harness — computed task] The computed task text follows:\n  x"
        #expect(WorkflowAgentPrompt.unframed(quoted) == nil)
        #expect(WorkflowAgentPrompt.unframed("[Workflow harness — computed task] it follows:\n  x") == nil)
        // Inside a relayed request every line is indented, so an indented frame there is the
        // request's, not the harness's.
        let relayed = "[Workflow harness — user request] Relayed:\n  [Workflow harness — computed task] The computed task text follows:\n  x"
        #expect(WorkflowAgentPrompt.unframed(relayed) == "")
    }

    /// Its last call hands its result back to the script.
    @Test func anAgentEndsByReturningItsResult() throws {
        let items = try agentItems()
        guard case .toolCall(let last)? = items.last else { Issue.record("no call last"); return }
        #expect(last.isStructuredOutput)
        #expect(last.input["findings"]?.arrayValue?.count == 1)
    }
}
