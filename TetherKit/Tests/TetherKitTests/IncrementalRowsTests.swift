import Foundation
import Observation
import Testing
import TetherProtocol
@testable import TetherKit

/// `ThreadModel.rows(_:)` folds a turn at a time and keeps the finished ones. Whatever it keeps, it
/// must return what folding and decorating every item at once returns, at every step of a chat.
@MainActor
@Suite
struct IncrementalRowsTests {
    private let threadID = "incremental"
    /// A Monday morning, in ms, so the script's gaps and day changes are the date separators' own.
    private let t0: Double = 1_790_000_000_000

    // MARK: items

    private func at(_ minutes: Double) -> Double { t0 + minutes * 60_000 }

    private func prompt(_ id: String, _ minutes: Double, synthetic: Bool? = nil) -> Item {
        .userMessage(.init(id: id, createdAt: at(minutes), content: [.text(.init(text: "Prompt \(id), with more words after it"))],
                           synthetic: synthetic))
    }

    private func reply(_ id: String, _ minutes: Double, text: String = "Done.", parent: String? = nil) -> Item {
        .agentMessage(.init(id: id, parentToolUseId: parent, createdAt: at(minutes), text: text))
    }

    private func call(_ id: String, _ minutes: Double, kind: ToolKind = .bash, status: ToolStatus = .completed,
                      parent: String? = nil) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: at(minutes), name: "Bash", kind: kind,
                        input: ["command": .string("echo \(id)")], status: status))
    }

    private func edit(_ id: String, _ minutes: Double, path: String = "/repo/a.swift", status: ToolStatus = .completed,
                      parent: String? = nil) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: at(minutes), name: "Edit", kind: .fileEdit,
                        input: ["file_path": .string(path), "old_string": "one\ntwo\nthree", "new_string": .string("one\n\(id)\nthree\nfour")],
                        status: status))
    }

    private func write(_ id: String, _ minutes: Double, parent: String? = nil) -> Item {
        .toolCall(.init(id: id, parentToolUseId: parent, createdAt: at(minutes), name: "Write", kind: .fileWrite,
                        input: ["file_path": .string("/repo/\(id).swift"), "content": "a\nb\n"], status: .completed))
    }

    private func subagent(_ id: String, _ minutes: Double, status: ToolStatus) -> Item {
        .toolCall(.init(id: id, createdAt: at(minutes), name: "Task", kind: .subagent,
                        input: ["description": "Look around"], status: status))
    }

    private func reasoning(_ id: String, _ minutes: Double) -> Item {
        .reasoning(.init(id: id, createdAt: at(minutes), text: "Thinking it over"))
    }

    // MARK: the reference

    /// The rows as they were made before: every item folded and decorated at once.
    private func fromScratch(_ thread: ThreadModel, _ folding: TranscriptFolding) -> [TranscriptRow] {
        let items = thread.items
        let top = items.filter { $0.parentToolUseId == nil }
        let running = thread.isRunning
        let folded = foldTranscriptRows(top, folding: folding, lastTurnRunning: running)
        return decorateTranscriptRows(folded, dates: DateSeparators.prompts(in: top),
                                      edits: turnEdits(in: items, lastTurnRunning: running))
    }

    /// A chat's life: pages, turns with tool calls, edits, a subagent and its edits, replies
    /// streamed, a background command and a subagent edit finishing after their turn, an older page,
    /// a reload. `check` runs after each step but the streamed deltas, which leave the rows as they
    /// were (the rows draw the text from each item's box).
    private func play(_ thread: ThreadModel, check: (String) -> Void) {
        var seq = 100
        func send(_ n: (Int) -> ServerNotification) { seq += 1; thread.apply(n(seq)) }
        func started(_ item: Item) { send { .itemStarted(.init(threadId: threadID, seq: $0, item: item)) }; check("started \(item.id)") }
        func completed(_ item: Item) { send { .itemCompleted(.init(threadId: threadID, seq: $0, item: item)) }; check("completed \(item.id)") }
        func updated(_ item: Item) { send { .itemUpdated(.init(threadId: threadID, seq: $0, item: item)) }; check("updated \(item.id)") }
        func status(_ s: ThreadStatus) { send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: s)) }; check("status \(s)") }
        func turn(_ id: String, _ status: TurnStatus) {
            let t = Turn(id: id, status: status, startedAt: 0)
            send { status == .inProgress ? .turnStarted(.init(threadId: threadID, seq: $0, turn: t))
                                         : .turnCompleted(.init(threadId: threadID, seq: $0, turn: t)) }
            check("turn \(id) \(status)")
        }
        func delta(_ id: String, _ text: String) {
            send { .itemAgentMessageDelta(.init(threadId: threadID, seq: $0, itemId: id, delta: text)) }
        }

        // The last page of a chat picked up yesterday: something before its first prompt, two turns.
        thread.loadHistory(items: [
            call("h0", -1500), reply("h1", -1499),
            prompt("p1", -1440), call("h2", -1439), call("h3", -1438, kind: .fileRead), edit("h4", -1437),
            reasoning("h5", -1436), write("h6", -1435), reply("h7", -1434),
            prompt("p2", -1430), call("h8", -1429), reply("h9", -1428),
        ], turns: [], seq: seq, hasMore: true)
        check("first page")

        // A turn with work, a background command, a subagent that edits, and a streamed reply.
        status(.running)
        turn("t3", .inProgress)
        started(prompt("p3", 0))
        started(call("c1", 1, status: .running))
        completed(call("c1", 1))
        started(call("bg", 2, status: .running))
        started(subagent("s1", 3, status: .running))
        started(call("s1-read", 3.1, kind: .fileRead, status: .running, parent: "s1"))
        completed(call("s1-read", 3.1, kind: .fileRead, parent: "s1"))
        started(edit("s1-edit", 3.2, status: .running, parent: "s1"))
        started(reply("s1-note", 3.3, text: "", parent: "s1"))
        completed(reply("s1-note", 3.3, text: "Found it.", parent: "s1"))
        started(edit("e1", 4, status: .running))
        completed(edit("e1", 4))
        started(reasoning("r1", 4.5))
        started(reply("a3", 5, text: ""))
        delta("a3", "Here ")
        delta("a3", "it is.")
        completed(reply("a3", 5, text: "Here it is."))
        turn("t3", .completed)
        status(.idle)

        // The next turn, ten minutes later: no date. The background command and the subagent's
        // edit finish while it runs, after their own turn.
        status(.running)
        turn("t4", .inProgress)
        started(prompt("p4", 10))
        started(call("c2", 11, kind: .grep, status: .running))
        completed(call("bg", 2))
        completed(edit("s1-edit", 3.2, parent: "s1"))
        completed(subagent("s1", 3, status: .completed))
        completed(call("c2", 11, kind: .grep))
        updated(call("c2", 11, kind: .grep, status: .failed))
        started(reply("a4", 12, text: ""))
        delta("a4", "Fixed.")
        completed(reply("a4", 12, text: "Fixed."))
        turn("t4", .completed)
        status(.idle)

        // A synthetic prompt, a prompt two hours later, and one with no time at all.
        started(prompt("p5", 20, synthetic: true))
        started(reply("a5", 21))
        started(prompt("p6", 140))
        started(write("w6", 141))
        started(.notice(.init(id: "n6", createdAt: at(142), kind: "info", text: "Compacted")))
        started(.userMessage(.init(id: "p7", createdAt: 0, content: [.text(.init(text: "Timeless"))])))
        started(edit("e7", 150))
        started(.error(.init(id: "x7", createdAt: at(151), message: "Overloaded")))

        // The page before the first one held, which ends on finished calls.
        thread.prependHistory(items: [prompt("p0", -3000), edit("o1", -2999), call("o2", -2998), call("o3", -1501)], hasMore: false)
        check("older page")

        // A reload of everything held.
        thread.loadHistory(items: thread.items, turns: thread.turns, seq: seq)
        check("reload")
        status(.running)
        turn("t8", .inProgress)
        started(prompt("p8", 200))
        started(edit("e8", 201))
        started(call("s8", 202, kind: .subagent, status: .running))
        started(edit("s8-edit", 203, parent: "s8"))
        turn("t8", .interrupted)
        status(.idle)
    }

    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor])
    func turnByTurnIsTheSameAsAllAtOnce(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        var steps = 0
        play(thread) { step in
            steps += 1
            let expected = fromScratch(thread, folding)
            #expect(thread.rows(folding) == expected, "after \(step)")
            #expect(thread.prompts(folding) == TranscriptPrompt.list(in: expected), "after \(step)")
        }
        #expect(steps > 40)
        // The script reached everything it's meant to: dates, a turn's edits, Worked For.
        let rows = thread.rows(folding)
        #expect(rows.contains { if case .dateSeparator = $0 { true } else { false } })
        #expect(rows.contains { if case .turnEdits(let e) = $0 { e.files.count > 1 } else { false } })
        if folding == .workedFor { #expect(rows.contains { if case .turnWork = $0 { true } else { false } }) }
    }

    /// Asked for only now and then, it folds again from the earliest change since.
    @Test(arguments: [TranscriptFolding.summarized, .workedFor])
    func askingNowAndThenIsTheSameAsAllAtOnce(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        var step = 0
        play(thread) { name in
            step += 1
            guard step % 4 == 0 else { return }
            #expect(thread.rows(folding) == fromScratch(thread, folding), "after \(name)")
        }
        #expect(thread.rows(folding) == fromScratch(thread, folding))
    }

    /// A change of Tool Calls setting folds everything its way; the previous folding isn't kept.
    @Test func switchingFoldingIsTheSameAsAllAtOnce() {
        let thread = ThreadModel(id: threadID)
        let foldings: [TranscriptFolding] = [.summarized, .everyCall, .workedFor]
        var step = 0
        play(thread) { name in
            step += 1
            let folding = foldings[step % foldings.count]
            #expect(thread.rows(folding) == fromScratch(thread, folding), "after \(name)")
            #expect(thread.foldingsHeld == [folding])
        }
    }

    /// A running call's row keeps the value it was folded with; its progress goes to its box, which
    /// the row draws. It folds again with its item once it finishes.
    @Test func progressGoesToTheBoxNotTheRows() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), call("bg", 1, status: .running), reply("a1", 2),
                                   prompt("p2", 3)], turns: [], seq: 1)
        _ = thread.rows(.summarized)
        thread.apply(.itemToolCallProgress(.init(threadId: threadID, seq: 2, itemId: "bg", elapsedSeconds: 30)))
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: call("c2", 4))))
        let rows = thread.rows(.summarized)
        #expect(rows.map(\.id) == fromScratch(thread, .summarized).map(\.id))
        guard case .toolCall(let live) = thread.box(for: thread.items[1]).item else { Issue.record("expected the call"); return }
        #expect(live.elapsedSeconds == 30)

        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 4, item: call("bg", 1))))
        #expect(thread.rows(.summarized) == fromScratch(thread, .summarized))
    }

    // MARK: what the transcript observes

    /// A subagent's steps show in its card, not the transcript: they don't fold the rows again, and
    /// only its card, which reads `children(of:)`, hears of them.
    @Test func aSubagentsStepsLeaveTheTranscriptAlone() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), subagent("s1", 1, status: .running)], turns: [], seq: 1)
        let transcript = Changed()
        withObservationTracking { _ = thread.rows(.summarized) } onChange: { transcript.happened = true }
        let card = Changed()
        withObservationTracking { _ = thread.children(of: "s1") } onChange: { card.happened = true }

        thread.apply(.itemStarted(.init(threadId: threadID, seq: 2, item: call("s1-read", 2, kind: .fileRead, status: .running, parent: "s1"))))
        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 3, item: call("s1-read", 2, kind: .fileRead, parent: "s1"))))

        #expect(!transcript.happened)
        #expect(card.happened)
        #expect(thread.children(of: "s1").map(\.id) == ["s1-read"])
        guard case .toolCall(let child) = thread.children(of: "s1").first else { Issue.record("expected the call"); return }
        #expect(child.status == .completed)
    }

    /// A subagent's edit counts in its turn's edits, so it does fold the rows again.
    @Test func aSubagentsEditFoldsTheRowsAgain() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), subagent("s1", 1, status: .completed), reply("a1", 2)], turns: [], seq: 1)
        _ = thread.rows(.summarized)
        let transcript = Changed()
        withObservationTracking { _ = thread.rows(.summarized) } onChange: { transcript.happened = true }

        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 2, item: edit("s1-edit", 1.5, parent: "s1"))))

        #expect(transcript.happened)
        #expect(thread.rows(.summarized).last?.id == "edits-p1")
    }

    /// The last item may be a subagent's, so "Thinking…" still follows them.
    @Test func thinkingFollowsASubagentsSteps() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p1", 0), subagent("s1", 1, status: .running)], turns: [], seq: 1)
        thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 2, status: .running)))
        #expect(!thread.isThinking)
        let tail = Changed()
        withObservationTracking { _ = thread.isThinking } onChange: { tail.happened = true }
        thread.apply(.itemStarted(.init(threadId: threadID, seq: 3, item: reply("s1-note", 2, text: "", parent: "s1"))))
        #expect(tail.happened)
        #expect(thread.isThinking)
    }

    /// The transcript's scroll state keeps the reader's row in place when an older page goes in
    /// above it, from `pageAnchor`, which nothing but a page changes.
    @Test func onlyAnOlderPageMovesTheAnchor() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p2", 0), reply("a2", 1)], turns: [], seq: 1, hasMore: true)
        #expect(thread.rows(.summarized).first?.id == "date-p2")
        let anchor = Changed()
        withObservationTracking { _ = thread.pageAnchor } onChange: { anchor.happened = true }

        thread.apply(.itemStarted(.init(threadId: threadID, seq: 2, item: prompt("p3", 2))))
        thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 3, status: .running)))
        #expect(!anchor.happened)
        #expect(thread.pageAnchor == nil)

        // A page from five minutes before takes the date off p2 (unless midnight came between):
        // then its prompt keeps its place instead.
        thread.prependHistory(items: [prompt("p1", -5), call("o1", -4)], hasMore: true)
        let rows = thread.rows(.summarized)
        #expect(anchor.happened)
        #expect(thread.pageAnchor?.rowID == (rows.contains { $0.id == "date-p2" } ? "date-p2" : "p2"))
        #expect(rows.first?.id == "date-p1")

        // The same page again adds nothing, and moves nothing.
        let again = thread.pageAnchor
        thread.prependHistory(items: [prompt("p1", -5)], hasMore: false)
        #expect(thread.pageAnchor == again)
    }

    @Test func aPageThatAddsNoRowsMovesNothing() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [prompt("p2", 0)], turns: [], seq: 1, hasMore: true)
        _ = thread.rows(.everyCall)
        thread.prependHistory(items: [reasoning("r0", -1)], hasMore: false)
        #expect(thread.pageAnchor == nil)
    }
}

/// Observation's `onChange` is `@Sendable`, so the flag it sets needs a reference to live in.
private final class Changed: @unchecked Sendable {
    var happened = false
}
