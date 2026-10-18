@testable import SundownFixtures
import SundownTestSupport
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

/// A scheduled job's wakeup in a real chat (`sampleScheduledWork`, from the loop-goal capture).
@MainActor @Suite struct WakeupTurnTests {
    /// A wakeup starts a turn as a prompt does: it gets its turn's message actions and Copy, and
    /// isn't one of the reader's prompts.
    @Test func aWakeupStartsATurn() {
        let thread = ThreadModel.sampleScheduledWork(finished: true)
        let rows = thread.rows(.summarized)
        let prompts = TranscriptPrompt.list(in: rows)
        #expect(!prompts.contains { $0.id.hasPrefix("wakeup") })
        let places = TurnPlaces(rows, prompts: prompts, running: false)
        #expect(places.turns["wakeup-1"] == "wakeup-1")
        // The turn's last reply ends the turn the wakeup started, not the /loop prompt's.
        let reply = thread.items.firstIndex { $0.id == "wakeup-1" }.map { i in
            thread.items[i...].first { if case .agentMessage = $0 { true } else { false } }!.id
        }!
        #expect(places.turns[reply] == "wakeup-1")
        #expect(places.ends.contains(reply))
        #expect(thread.turnReplies(through: reply) == ["It’s 22:13:14."])
    }
}
