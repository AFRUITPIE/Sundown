import Foundation
@testable import SundownFixtures
import Testing
import TetherProtocol
@testable import SundownKit

@MainActor
@Suite
struct TurnEditsTests {
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

    // MARK: lines

    /// A final newline doesn't count as a line of its own, on either side.
    @Test func aFinalNewlineIsNotALine() {
        #expect(LineDiff.split("") == [])
        #expect(LineDiff.split("a\nb\n") == ["a", "b"])
    }

    /// Two texts compared, as a request's proposed edit is: each removal just before what replaced it.
    @Test func twoTextsAreComparedLineByLine() {
        let lines = LineDiff.lines(old: "a\nb\nc", new: "a\nx\nc\nd")
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context, .added])
    }

    /// A hunk's lines as the daemon writes them, "No newline at end of file" left out.
    @Test func aHunksLinesAreReadByTheirSigns() {
        let hunk = DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [" a", "-b", "+c", "\\ No newline at end of file"])
        #expect(hunk.diffLines == [.init(.context, "a"), .init(.removed, "b"), .init(.added, "c")])
    }

    /// The samples' and the fixture's edits are compared from the call's input, as the daemon
    /// compares a call Claude Code reported no patch for; only a finished one changed anything.
    @Test func aSamplesEditIsComparedFromItsInput() throws {
        let w = try #require(write("w", "/r/new.swift", "one\ntwo\nthree\n").toolCall?.edit)
        #expect((w.added, w.removed) == (3, 0))
        let multi = try #require(Item.ToolCall.sample(name: "MultiEdit", kind: .fileEdit, input: [
            "file_path": "/r/a.swift",
            "edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "c\nd"]],
        ], secondsAgo: 1).edit)
        #expect(multi.hunks.count == 2)
        #expect((multi.added, multi.removed) == (2, 1))
        for status in [ToolStatus.failed, .denied, .interrupted, .running, .pending] {
            #expect(edit("e", "/r/a.swift", old: "a", new: "b", status: status).toolCall?.edit == nil, "\(status)")
        }
        #expect(read("r", "/r/a.swift").toolCall?.edit == nil)
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
        let edits = try #require(EditedFiles.summarize(promptID: "p1", items))
        #expect(edits.files.map(\.path) == ["/r/a.swift", "/r/b.swift"])
        #expect(edits.files[0].edits.count == 2)
        #expect((edits.files[0].added, edits.files[0].removed) == (2, 1))
        #expect((edits.added, edits.removed) == (4, 1))
        // The turn's own totals, when the daemon has said them, are its counts.
        let totals = try #require(EditedFiles.summarize(promptID: "p1", items, totals: .init(files: 3, added: 9, removed: 2)))
        #expect((totals.added, totals.removed) == (9, 2))
        #expect(totals.files.map(\.path) == ["/r/a.swift", "/r/b.swift"])
    }

    @Test func aTurnThatEditedNothingHasNoSummary() {
        #expect(EditedFiles.summarize(promptID: "p1", [read("r1", "/r/a.swift"), reply("m1")]) == nil)
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
        let edits = editedFiles(in: items, lastTurnRunning: false)
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
        #expect(Set(editedFiles(in: items, lastTurnRunning: true).keys) == ["p1"])
        #expect(Set(editedFiles(in: items, lastTurnRunning: false).keys) == ["p1", "p2"])
    }

    // MARK: rows

    /// Edits after the turn's last row, before the next prompt and its date.
    @Test func decorationsGoBetweenTurns() {
        let items = [prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1"), prompt("p2"), reply("m2")]
        let edits = editedFiles(in: items, lastTurnRunning: false)
        let rows = decorateTranscriptRows(foldTranscriptRows(items), dates: ["p1": 1_000, "p2": 5_000], edits: edits)
        #expect(rows.map(\.id) == ["date-p1", "p1", "e1", "m1", "edits-p1", "date-p2", "p2", "m2"])
    }

    /// A turn whose last row is a run of calls (or a call) has its edits in that row, one line:
    /// "Ran a command and edited a.swift", not two quiet lines in a row.
    @Test func editsRightAfterARunAreThatRows() throws {
        let bash = Item.toolCall(.init(id: "b1", createdAt: 1_100, name: "Bash", kind: .bash, input: ["command": "make"], status: .completed))
        let lone = [prompt("p1"), reply("m1"), edit("e1", "/r/a.swift", old: "a", new: "b"), prompt("p2"), reply("m2")]
        let rows = decorateTranscriptRows(foldTranscriptRows(lone), dates: [:], edits: editedFiles(in: lone, lastTurnRunning: false))
        #expect(rows.map(\.id) == ["p1", "m1", "group-e1", "p2", "m2"])
        guard case .toolGroup(let calls, let edits?) = rows[2] else { Issue.record("no joined row"); return }
        #expect(calls.map(\.id) == ["e1"])
        #expect(edits.promptID == "p1")
        let run = [prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), bash]
        let joined = decorateTranscriptRows(foldTranscriptRows(run), dates: [:], edits: editedFiles(in: run, lastTurnRunning: false))
        #expect(joined.map(\.id) == ["p1", "group-e1"])
        guard case .toolGroup(_, let e?) = joined[1] else { Issue.record("no joined row"); return }
        #expect(e.files.map(\.path) == ["/r/a.swift"])
    }

    /// Worked For keeps the edits after the reply that ends the folded work.
    @Test func workedForKeepsTheEditsAfterTheReply() {
        let items = [prompt("p1"), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1")]
        let folded = foldTranscriptRows(items, folding: .workedFor, lastTurnRunning: false)
        let rows = decorateTranscriptRows(folded, dates: [:], edits: editedFiles(in: items, lastTurnRunning: false))
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

    /// A turn's totals, at its end or changed later by `turn/updated` (a background agent's edit),
    /// fold its rows again, though no item of it changed.
    @Test func aTurnsTotalsRedrawItsEdits() throws {
        var p1 = Item.UserMessage(id: "p1", createdAt: 1_000, content: [.text(.init(text: "p1"))])
        p1.turnId = "t1"
        let items: [Item] = [.userMessage(p1), edit("e1", "/r/a.swift", old: "a", new: "b"), reply("m1")]
        let thread = ThreadModel.sample(status: .idle, items: items, turns: [.init(id: "t1", status: .completed, startedAt: 1_000)])
        func counts() -> (Int, Int)? {
            for case .turnEdits(let e) in thread.rows(.summarized) { return (e.added, e.removed) }
            return nil
        }
        #expect(counts().map { $0 == (1, 1) } == true)
        var turn = Turn(id: "t1", status: .completed, startedAt: 1_000)
        turn.edits = .init(files: 2, added: 7, removed: 3)
        thread.apply(.turnUpdated(.init(threadId: thread.id, seq: 1, turn: turn)))
        #expect(counts().map { $0 == (7, 3) } == true)
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
