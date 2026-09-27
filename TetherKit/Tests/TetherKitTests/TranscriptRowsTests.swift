import Testing
import TetherProtocol
@testable import TetherKit

@MainActor
@Suite
struct TranscriptRowsTests {
    private func call(_ id: String, kind: ToolKind = .bash, status: ToolStatus = .completed) -> Item {
        .toolCall(.sample(id: id, name: "Bash", kind: kind, input: ["command": "echo hi"], status: status, secondsAgo: 1))
    }

    private func message(_ id: String) -> Item {
        .agentMessage(.init(id: id, createdAt: 0, text: "hello"))
    }

    @Test func singleToolCallStaysUngrouped() {
        let rows = foldTranscriptRows([message("m1"), call("t1"), message("m2")])
        #expect(rows.count == 3)
        guard case .item(.toolCall(let t)) = rows[1] else { Issue.record("expected plain item"); return }
        #expect(t.id == "t1")
    }

    @Test func consecutiveCompletedCallsGroup() {
        let rows = foldTranscriptRows([message("m1"), call("t1"), call("t2"), call("t3"), message("m2")])
        #expect(rows.count == 3)
        guard case .toolGroup(let calls) = rows[1] else { Issue.record("expected a group"); return }
        #expect(calls.map(\.id) == ["t1", "t2", "t3"])
    }

    /// Settings ▸ Appearance ▸ Group Finished Calls off: every call on a row of its own.
    @Test func withoutGroupingEveryCallIsItsOwnRow() {
        let rows = foldTranscriptRows([message("m1"), call("t1"), call("t2"), call("t3"), message("m2")], grouping: false)
        #expect(rows.map(\.id) == ["m1", "t1", "t2", "t3", "m2"])
    }

    @Test func runningCallBreaksTheGroup() {
        let rows = foldTranscriptRows([call("t1"), call("t2", status: .running), call("t3")])
        // t1 alone, t2 alone (running), t3 alone — none of these runs has 2+ members.
        #expect(rows.count == 3)
        for row in rows { if case .toolGroup = row { Issue.record("did not expect a group") } }
    }

    @Test func runningCallStaysUngroupedBesideAFinishedGroup() {
        let rows = foldTranscriptRows([call("t1"), call("t2"), call("t3", status: .running)])
        #expect(rows.count == 2)
        guard case .toolGroup(let calls) = rows[0] else { Issue.record("expected a group first"); return }
        #expect(calls.map(\.id) == ["t1", "t2"])
        guard case .item(.toolCall(let running)) = rows[1] else { Issue.record("expected the running call alone"); return }
        #expect(running.id == "t3" && running.status == .running)
    }

    /// A failed or denied call is finished work too: it folds into the run, which says so.
    @Test func failedAndDeniedCallsJoinTheGroup() {
        let rows = foldTranscriptRows([call("t1"), call("t2", status: .failed), call("t3"), call("t4", status: .denied), call("t5")])
        #expect(rows.count == 1)
        guard case .toolGroup(let calls) = rows[0] else { Issue.record("expected one group"); return }
        #expect(calls.count == 5)
    }

    @Test func todoWriteNeverGroups() {
        let rows = foldTranscriptRows([call("t1"), call("todo", kind: .todoWrite), call("t2")])
        #expect(rows.count == 3)
        for row in rows { if case .toolGroup = row { Issue.record("todoWrite should never be grouped") } }
    }

    @Test func subagentNeverGroups() {
        let rows = foldTranscriptRows([call("t1"), call("agent", kind: .subagent), call("t2")])
        #expect(rows.count == 3)
        for row in rows { if case .toolGroup = row { Issue.record("subagent should never be grouped") } }
    }

    @Test func rowIdsAreStable() {
        let rows = foldTranscriptRows([call("t1"), call("t2")])
        #expect(rows.count == 1)
        #expect(rows[0].id == "group-t1")
    }

    @Test func emptyInputProducesNoRows() {
        #expect(foldTranscriptRows([]).isEmpty)
    }

    @Test func reasoningNeverReachesTheTranscript() {
        let reasoning = Item.reasoning(.init(id: "r1", createdAt: 0, text: "thinking out loud"))
        let rows = foldTranscriptRows([message("m1"), reasoning, message("m2")])
        #expect(rows.map(\.id) == ["m1", "m2"])
    }

    /// Reasoning between two tool calls mustn't split the run it sits in, now that it isn't drawn.
    @Test func reasoningDoesNotBreakAToolGroup() {
        let reasoning = Item.reasoning(.init(id: "r1", createdAt: 0, text: "picking the next step"))
        let rows = foldTranscriptRows([call("t1"), reasoning, call("t2")])
        #expect(rows.count == 1)
        guard case .toolGroup(let calls) = rows[0] else { Issue.record("expected a group"); return }
        #expect(calls.map(\.id) == ["t1", "t2"])
    }
}

@MainActor
@Suite
struct PagedHistoryTests {
    private func msg(_ id: String) -> Item { .agentMessage(.init(id: id, createdAt: 0, text: id)) }

    @Test func prependPutsOlderItemsInFront() {
        let thread = ThreadModel(id: "t")
        thread.loadHistory(items: [msg("c"), msg("d")], turns: [], seq: nil, hasMore: true)
        #expect(thread.hasMoreHistory)
        thread.prependHistory(items: [msg("a"), msg("b")], hasMore: false)
        #expect(thread.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(!thread.hasMoreHistory)
    }

    /// The index backs `itemIndex(of:)` and delta application, so it has to survive a prepend.
    @Test func prependReindexes() {
        let thread = ThreadModel(id: "t")
        thread.loadHistory(items: [msg("c")], turns: [], seq: nil, hasMore: true)
        thread.prependHistory(items: [msg("a"), msg("b")], hasMore: false)
        #expect(thread.itemIndex(of: "a") == 0)
        #expect(thread.itemIndex(of: "c") == 2)
    }

    /// A page that overlaps what is held would otherwise show the same rows twice.
    @Test func prependDropsItemsAlreadyHeld() {
        let thread = ThreadModel(id: "t")
        thread.loadHistory(items: [msg("b"), msg("c")], turns: [], seq: nil, hasMore: true)
        thread.prependHistory(items: [msg("a"), msg("b")], hasMore: false)
        #expect(thread.items.map(\.id) == ["a", "b", "c"])
    }

    @Test func emptyPageOnlyUpdatesTheFlag() {
        let thread = ThreadModel(id: "t")
        thread.loadHistory(items: [msg("a")], turns: [], seq: nil, hasMore: true)
        thread.prependHistory(items: [], hasMore: false)
        #expect(thread.items.map(\.id) == ["a"])
        #expect(!thread.hasMoreHistory)
    }
}
