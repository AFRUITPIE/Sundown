import Testing
import TetherProtocol
@testable import SundownKit

@MainActor @Suite struct TurnPlacesTests {
    private func prompt(_ id: String) -> TranscriptRow {
        .item(.userMessage(.init(id: id, createdAt: 0, content: [.text(.init(text: id))])))
    }
    private func reply(_ id: String) -> TranscriptRow { .item(.agentMessage(.init(id: id, createdAt: 0, text: id))) }

    /// A turn's actions go once, after its last reply, and not while that turn still runs.
    @Test func eachFinishedTurnEndsAtItsLastReply() {
        let rows: [TranscriptRow] = [
            .dateSeparator(promptID: "p1", ms: 0), prompt("p1"), reply("a"), reply("b"),
            prompt("p2"), reply("c"),
        ]
        let prompts = TranscriptPrompt.list(in: rows)
        let settled = TurnPlaces(rows, prompts: prompts, running: false)
        #expect(settled.ends == ["b", "c"])
        #expect(settled.turns["date-p1"] == "p1")
        #expect(settled.turns["a"] == "p1")
        #expect(settled.turns["c"] == "p2")
        #expect(TurnPlaces(rows, prompts: prompts, running: true).ends == ["b"])
    }

    @Test func aTurnKeepsItsRepliesForCopy() {
        let thread = ThreadModel(id: "t")
        var seq = 0
        func start(_ item: Item) { seq += 1; thread.apply(.itemStarted(.init(threadId: "t", seq: seq, item: item))) }
        start(.userMessage(.init(id: "p1", createdAt: 0, content: [.text(.init(text: "Hi"))])))
        start(.agentMessage(.init(id: "a", createdAt: 0, text: "One")))
        start(.agentMessage(.init(id: "b", createdAt: 0, text: "Two")))
        start(.userMessage(.init(id: "p2", createdAt: 0, content: [.text(.init(text: "Again"))])))
        start(.agentMessage(.init(id: "c", createdAt: 0, text: "Three")))
        #expect(thread.turnReplies(through: "b") == ["One", "Two"])
        #expect(thread.turnReplies(through: "c") == ["Three"])
    }
}
