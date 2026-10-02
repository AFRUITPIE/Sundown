import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

@MainActor
@Suite
struct TurnEditsTests {
    private func prompt(_ id: String, at ms: Double = 1_000) -> Item {
        .userMessage(.init(id: id, createdAt: ms, content: [.text(.init(text: "go"))]))
    }

    private func reply(_ id: String) -> Item {
        .agentMessage(.init(id: id, createdAt: 2_000, text: "done"))
    }

    private func edit(_ id: String, _ path: String, old: String, new: String, status: ToolStatus = .completed,
                      parent: String? = nil) -> Item {
        .toolCall(.sample(id: id, name: "Edit", kind: .fileEdit, input: ["file_path": .string(path), "old_string": .string(old),
                                                                          "new_string": .string(new)],
                          status: status, parentToolUseId: parent, secondsAgo: 1))
    }

    private func write(_ id: String, _ path: String, _ content: String) -> Item {
        .toolCall(.sample(id: id, name: "Write", kind: .fileWrite, input: ["file_path": .string(path), "content": .string(content)],
                          secondsAgo: 1))
    }

    private func read(_ id: String, _ path: String) -> Item {
        .toolCall(.sample(id: id, name: "Read", kind: .fileRead, input: ["file_path": .string(path)], secondsAgo: 1))
    }

    // MARK: counting

    /// Counted as the diff shows it: a line added beside one kept is one added, none removed.
    @Test func anEditCountsTheLinesItsDiffChanges() {
        #expect(LineDiff.counts(old: "a\nb", new: "a\nb\nc") == (1, 0))
        #expect(LineDiff.counts(old: "a\nb\nc", new: "a\nx\nc") == (1, 1))
        #expect(LineDiff.counts(old: "a\nb", new: "") == (0, 2))
    }

    /// A final newline doesn't count as a line of its own, on either side.
    @Test func aFinalNewlineIsNotALine() {
        #expect(LineDiff.split("") == [])
        #expect(LineDiff.split("a\nb\n") == ["a", "b"])
        #expect(LineDiff.counts(old: "a\n", new: "a\nb\n") == (1, 0))
    }

    @Test func theDiffShowsWhatTheCountsSay() {
        let lines = LineDiff.lines(old: "a\nb\nc", new: "a\nx\nc\nd")
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context, .added])
        #expect(lines.filter { $0.kind == .added }.count == LineDiff.counts(old: "a\nb\nc", new: "a\nx\nc\nd").added)
    }

    /// A Write's content is all added; a MultiEdit's edits are each a change; a NotebookEdit's source is added.
    @Test func eachKindOfEditIsReadFromItsInput() throws {
        let w = try #require(write("w", "/r/new.swift", "one\ntwo\nthree\n").toolCall)
        #expect(FileChange.changes(of: w).map { [$0.added, $0.removed] } == [[3, 0]])

        let multi = Item.ToolCall.sample(name: "MultiEdit", kind: .fileEdit, input: [
            "file_path": "/r/a.swift",
            "edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "c\nd"]],
        ], secondsAgo: 1)
        #expect(FileChange.changes(of: multi).map { [$0.added, $0.removed] } == [[1, 1], [1, 0]])

        let notebook = Item.ToolCall.sample(name: "NotebookEdit", kind: .notebookEdit, input: [
            "notebook_path": "/r/n.ipynb", "new_source": "print(1)\nprint(2)", "cell_id": "c1",
        ], secondsAgo: 1)
        #expect(FileChange.changes(of: notebook).map(\.added) == [2])
    }

    /// Only a finished call changed anything: one that failed, was denied or stopped didn't.
    @Test(arguments: [ToolStatus.failed, .denied, .interrupted, .running, .pending])
    func onlyCompletedEditsCount(status: ToolStatus) throws {
        let call = try #require(edit("e", "/r/a.swift", old: "a", new: "b", status: status).toolCall)
        #expect(FileChange.changes(of: call).isEmpty)
    }

    @Test func aReadChangesNothing() throws {
        let r = try #require(read("r", "/r/a.swift").toolCall)
        #expect(FileChange.changes(of: r).isEmpty)
    }

    // MARK: a turn

    /// Files in the order first changed, each with its changes in order and their sums.
    @Test func aTurnsEditsAreGroupedByFile() throws {
        let items = [
            edit("e1", "/r/a.swift", old: "a", new: "a\nb"),
            write("w1", "/r/b.swift", "x\ny"),
            read("r1", "/r/c.swift"),
            edit("e2", "/r/a.swift", old: "b", new: "c"),
            edit("e3", "/r/c.swift", old: "q", new: "z", status: .failed),
        ]
        let edits = try #require(TurnEdits.summarize(promptID: "p1", items))
        #expect(edits.files.map(\.path) == ["/r/a.swift", "/r/b.swift"])
        #expect(edits.files[0].changes.count == 2)
        #expect((edits.files[0].added, edits.files[0].removed) == (2, 1))
        #expect((edits.added, edits.removed) == (4, 1))
    }

    @Test func aTurnThatEditedNothingHasNoSummary() {
        #expect(TurnEdits.summarize(promptID: "p1", [read("r1", "/r/a.swift"), reply("m1")]) == nil)
    }

    // MARK: turns

    /// Each finished turn's edits, by its prompt; a subagent's edits belong to the turn it ran in,
    /// and its own prompt doesn't start one.
    @Test func editsAreCollectedPerTurn() {
        let subagentPrompt = Item.userMessage(.init(id: "sub-p", parentToolUseId: "agent", createdAt: 1_500,
                                                    content: [.text(.init(text: "look"))]))
        let items = [
            prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1"),
            prompt("p2"), read("r1", "/r/a.swift"), reply("m2"),
            prompt("p3"), subagentPrompt, edit("e2", "/r/b.swift", old: "a", new: "b", parent: "agent"), reply("m3"),
        ]
        let edits = turnEdits(in: items, lastTurnRunning: false)
        #expect(Set(edits.keys) == ["p1", "p3"])
        #expect(edits["p3"]?.files.map(\.path) == ["/r/b.swift"])
    }

    /// The turn still running has none yet; the items before the first prompt held — the end of a
    /// turn whose prompt is on an older page — have none, since there's no prompt to restore to.
    @Test func runningAndPromptlessTurnsHaveNone() {
        let items = [
            edit("e0", "/r/z.swift", old: "a", new: "b"),
            prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1"),
            prompt("p2"), edit("e2", "/r/b.swift", old: "a", new: "b"),
        ]
        #expect(Set(turnEdits(in: items, lastTurnRunning: true).keys) == ["p1"])
        #expect(Set(turnEdits(in: items, lastTurnRunning: false).keys) == ["p1", "p2"])
    }

    // MARK: rows

    /// Edits after the turn's last row, before the next prompt and its date.
    @Test func decorationsGoBetweenTurns() {
        let items = [prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1"), prompt("p2"), reply("m2")]
        let edits = turnEdits(in: items, lastTurnRunning: false)
        let rows = decorateTranscriptRows(foldTranscriptRows(items), dates: ["p1": 1_000, "p2": 5_000], edits: edits)
        #expect(rows.map(\.id) == ["date-p1", "p1", "e1", "m1", "edits-p1", "date-p2", "p2", "m2"])
    }

    /// Worked For keeps the edits after the reply that ends the folded work.
    @Test func workedForKeepsTheEditsAfterTheReply() {
        let items = [prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1")]
        let folded = foldTranscriptRows(items, folding: .workedFor, lastTurnRunning: false)
        let rows = decorateTranscriptRows(folded, dates: [:], edits: turnEdits(in: items, lastTurnRunning: false))
        #expect(rows.map(\.id) == ["p1", "work-p1", "m1", "edits-p1"])
    }

    /// The thread shows a turn's edits once it's finished, in every folding, and not while it runs.
    @Test(arguments: [TranscriptFolding.summarized, .workedFor, .everyCall])
    func theThreadShowsEditsOnlyForFinishedTurns(folding: TranscriptFolding) {
        let items = [prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1")]
        let running = ThreadModel.sample(status: .running, items: items)
        #expect(!running.rows(folding).contains { $0.id == "edits-p1" })
        let idle = ThreadModel.sample(status: .idle, items: items)
        #expect(idle.rows(folding).last?.id == "edits-p1")
    }

    /// Streamed text doesn't bump the transcript's version, so the rows (and the edits) aren't
    /// worked out again per token.
    @Test func streamedTextDoesNotRecomputeTheRows() {
        let thread = ThreadModel.sample(status: .running, items: [prompt("p1"), reply("m1")])
        let version = thread.itemsVersion
        thread.apply(.itemAgentMessageDelta(.init(threadId: thread.id, seq: 1, itemId: "m1", delta: " more")))
        #expect(thread.itemsVersion == version)
    }
}
