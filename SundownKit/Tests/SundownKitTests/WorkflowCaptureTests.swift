import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// Two real dynamic workflows' items, as Claude Code 2.1.291 ran them and the daemon itemized them:
/// one agent's transcript of "typo-check" (`Fixtures/workflow-typo-check-agent-items.json`, as
/// `workflow/agentItems` serves it), and "slow-check"'s notifications
/// (`Fixtures/workflow-slow-check-notifications.jsonl`, made by the server's itemizer from its
/// capture). How each run stands is the daemon's to say (its tasks), and its tests'.
@MainActor
@Suite
struct WorkflowCaptureTests {
    private let threadID = "dc2cc722"

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A daemon may say a workflow has finished at once, by a message of its own with a stable id,
    /// and fill in its result once it has it: one item, holding the latest (in Tasks, not a row).
    @Test func theFinishIsOneItemUpdatedInPlace() throws {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [], turns: [], seq: 0)
        func finish(_ text: String) -> Item {
            .userMessage(.init(id: "workflow-finish-wsjxcgcst", createdAt: 1_791_322_778_430, content: [.text(.init(text: text))],
                               synthetic: true, origin: "workflow", originName: "typo-check"))
        }
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 1, item: finish("Workflow completed"))))
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 2, item: finish(#"{"verified":[]}"#))))
        let held = thread.items.filter { $0.id == "workflow-finish-wsjxcgcst" }
        #expect(held.count == 1)
        guard case .userMessage(let m)? = held.first, case .text(let t)? = m.content.first else {
            Issue.record("no finish"); return
        }
        #expect(t.text == #"{"verified":[]}"#)
        #expect(!thread.rows(.summarized).contains { $0.id == "workflow-finish-wsjxcgcst" }, "the result is in Tasks")
    }

    // MARK: slow-check, as the daemon sends it

    /// A second real run in the same chat, slow-check, whose three Wait agents each ran `sleep 45`
    /// in the background: the notifications the daemon sends for it
    /// (`Fixtures/workflow-slow-check-notifications.jsonl`, made by the server's itemizer from its
    /// capture). The CLI's `<task-notification>` message never reaches the stream, so the finish is
    /// the daemon's from the task's event, with the run record's result; the agents' commands are
    /// no line in the chat.
    private func slowCheck() throws -> ThreadModel {
        let text = String(decoding: try Self.fixture("workflow-slow-check-notifications", "jsonl"), as: UTF8.self)
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [], turns: [], seq: 0)
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            let message = try decoder.decode(JSONValue.self, from: Data(line.utf8))
            let method = try #require(message["method"]?.stringValue)
            let params = try JSONEncoder().encode(try #require(message["params"]))
            thread.apply(try ServerNotification(method: method, params: params, decoder: decoder))
        }
        return thread
    }

    @Test func slowChecksFinishComesBeforeTheReplyAnsweringIt() throws {
        let thread = try slowCheck()
        let items = thread.topLevelItems
        let at = try #require(items.firstIndex { $0.id == "workflow_wmcpqnf9b_finished" })
        guard case .userMessage(let finish) = items[at], case .text(let t)? = finish.content.first else {
            Issue.record("no finish"); return
        }
        #expect(finish.origin == "workflow")
        #expect(finish.originName == "slow-check")
        #expect(t.text.contains(#""report": "all waited""#))
        #expect(items.dropFirst(at + 1).first { if case .reasoning = $0 { false } else { true } }?.id == "msg_011Cfmk8tuutNMNdJrxLtVJV:0")
        // In the chat, the reply stands for it.
        #expect(!thread.rows(.summarized).contains { $0.id == finish.id })
        #expect(thread.turns.map(\.id).last == "turn_workflow_wmcpqnf9b_finished")
        #expect(!thread.topLevelItems.contains { if case .notice = $0 { true } else { false } })
    }

    // MARK: an agent's transcript

    /// The agent's transcript as the daemon's `readAgentItems` serves it, its prompt unframed.
    private func agentItems() throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: try Self.fixture("workflow-typo-check-agent-items", "json"))
    }

    /// Its last call hands its result back to the script.
    @Test func anAgentEndsByReturningItsResult() throws {
        let items = try agentItems()
        guard case .toolCall(let last)? = items.last else { Issue.record("no call last"); return }
        #expect(last.isStructuredOutput)
        #expect(last.input["findings"]?.arrayValue?.count == 1)
    }
}
