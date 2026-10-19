import Foundation
import Observation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownTestSupport

/// `ThreadModel.rows(_:)` keeps the turns before the last one and folds the last again. Whatever it
/// keeps, it must return what folding and decorating every item at once returns, at every step of a
/// chat: `TranscriptStabilityTests`' random walk holds it so; these hold what a step leaves alone.
@MainActor
@Suite
struct IncrementalRowsTests: TimedItems {
    private let threadID = "incremental"

    /// A running call's row keeps the value it was folded with; its progress goes to its box, which
    /// the row draws. It folds again with its item once it finishes.
    @Test func progressGoesToTheBoxNotTheRows() throws {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), call("bg", 1, status: .running), reply("a1", 2),
                                   prompt("p2", 3)], turns: [], seq: 1)
        _ = thread.rows(.summarized)
        thread.apply(.itemToolCallProgress(.init(threadId: threadID, seq: 2, itemId: "bg", elapsedSeconds: 30)))
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: call("c2", 4))))
        let rows = thread.rows(.summarized)
        #expect(rows.map(\.id) == rowsFromScratch(thread, .summarized).map(\.id))
        let live = try #require(thread.box(for: thread.items[1]).item.toolCall)
        #expect(live.elapsedSeconds == 30)

        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 4, item: call("bg", 1))))
        #expect(thread.rows(.summarized) == rowsFromScratch(thread, .summarized))
    }

    // MARK: what the transcript observes

    /// A subagent's steps show in its card, not the transcript: they don't fold the rows again, and
    /// only its card, which reads `children(of:)`, hears of them.
    @Test func aSubagentsStepsLeaveTheTranscriptAlone() throws {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), subagent("s1", 1, status: .running)], turns: [], seq: 1)
        let transcript = observing { _ = thread.rows(.summarized) }
        let card = observing { _ = thread.children(of: "s1") }

        thread.apply(.itemStarted(.init(threadId: threadID, seq: 2, item: call("s1-read", 2, kind: .fileRead, status: .running, parent: "s1"))))
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 3, item: call("s1-read", 2, kind: .fileRead, parent: "s1"))))

        #expect(!transcript.happened)
        #expect(card.happened)
        #expect(thread.children(of: "s1").map(\.id) == ["s1-read"])
        let child = try #require(thread.children(of: "s1").first?.toolCall)
        #expect(child.status == .completed)
    }

    /// A subagent's edit counts in its turn's edits, so it does fold the rows again.
    @Test func aSubagentsEditFoldsTheRowsAgain() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), subagent("s1", 1, status: .completed), reply("a1", 2)], turns: [], seq: 1)
        _ = thread.rows(.summarized)
        let transcript = observing { _ = thread.rows(.summarized) }

        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 2, item: edit("s1-edit", 1.5, parent: "s1"))))

        #expect(transcript.happened)
        #expect(thread.rows(.summarized).last?.id == "edits-p1")
    }

    /// A running subagent's own steps don't move "Thinking…": each one came and went with them,
    /// many times a second, moving the whole transcript under the Agent call's row.
    @Test func thinkingIgnoresASubagentsSteps() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), subagent("s1", 1, status: .running)], turns: [], seq: 1)
        thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 2, status: .running)))
        #expect(!thread.isThinking)
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: reply("s1-note", 2, text: "", parent: "s1"))))
        #expect(!thread.isThinking)
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 4, item: reply("s1-note", 2, text: "Done.", parent: "s1"))))
        #expect(!thread.isThinking)
    }
}
