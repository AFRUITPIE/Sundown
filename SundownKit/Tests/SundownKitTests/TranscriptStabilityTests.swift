import Foundation
import Testing
import TetherProtocol
@testable import SundownKit
import SundownTestSupport

/// What a bounce or a blank transcript needs from the rows: a reader's rows keep their ids and order
/// when the chat under them reloads, grows, gets an older page, is trimmed and restored, or has a
/// turn end. Each assertion is one property that, if it failed, would move the content under the
/// reader or leave it empty.
@MainActor
@Suite(.serialized)
struct TranscriptStabilityTests: TimedItems {
    private let threadID = "stability"
    private let foldings: [TranscriptFolding] = [.summarized, .everyCall, .workedFor]

    // MARK: items

    /// A chat of `turns` turns, each a prompt, a command, an edit and a reply, with a subagent and
    /// its edit every fifth turn and a gap of hours every fourth. `chat(turns: 5)` is a prefix of
    /// `chat(turns: 8)`, so one can stand for a chat that grew into the other.
    private func chat(turns: Int, from start: Double = 0, tag: String = "") -> [Item] {
        var items: [Item] = []
        var m = start
        for i in 0..<turns {
            m += i % 4 == 3 ? 200 : 20
            items.append(prompt("\(tag)p\(i)", m))
            items.append(call("\(tag)c\(i)", m + 1))
            items.append(edit("\(tag)e\(i)", m + 2, path: "/repo/f\(i % 3).swift"))
            if i % 5 == 4 {
                items.append(subagent("\(tag)s\(i)", m + 3, status: .completed))
                items.append(edit("\(tag)se\(i)", m + 3.5, parent: "\(tag)s\(i)"))
            }
            items.append(reply("\(tag)a\(i)", m + 4, text: "Reply \(i)"))
        }
        return items
    }

    // MARK: 1. a reload with the same items

    /// A replay-gap reload hands back the same items. Every row keeps its id and its place, whether
    /// or not the turn under the reader is still running.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor], [false, true])
    func reloadWithTheSameItemsKeepsEveryRowIdInOrder(_ folding: TranscriptFolding, running: Bool) {
        let thread = ThreadModel(id: threadID)
        var items = chat(turns: 9)
        if running { items += [prompt("pLive", 900), call("cLive", 901, status: .running)] }
        thread.loadHistory(items: items, turns: [], seq: 1)
        if running { thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 2, status: .running))) }
        let before = thread.rows(folding)

        thread.loadHistory(items: items, turns: [], seq: running ? 2 : 1)

        let after = thread.rows(folding)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after == before)
    }

    // MARK: 2. a reload with more items

    /// A chat that grew while the app was away: the rows it held keep their ids, and the new ones
    /// come after.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor])
    func aReloadWithItemsAppendedKeepsTheEarlierRowIds(_ folding: TranscriptFolding) {
        let five = chat(turns: 5), eight = chat(turns: 8)
        #expect(Array(eight.prefix(five.count)).map(\.id) == five.map(\.id), "the fixture's superset premise")
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: five, turns: [], seq: 1)
        let before = thread.rows(folding).map(\.id)

        thread.loadHistory(items: eight, turns: [], seq: 1)

        let after = thread.rows(folding).map(\.id)
        #expect(after.count > before.count)
        #expect(Array(after.prefix(before.count)) == before)
    }

    // MARK: 3. an older page

    /// An older page from a day before goes in above the reader: every row the reader had is still
    /// there, in order, and the new rows all come before them.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor])
    func prependingAnOlderPageKeepsEveryRowAndItsOrder(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: chat(turns: 4, from: 1_000, tag: "tail"), turns: [], seq: 1, hasMore: true)
        let before = thread.rows(folding).map(\.id)

        thread.prependHistory(items: chat(turns: 3, from: -5_000, tag: "head"), hasMore: false)

        let after = thread.rows(folding).map(\.id)
        #expect(after.count > before.count)
        #expect(Array(after.suffix(before.count)) == before)
    }

    /// An older page whose last prompt is ten minutes before the reader's first one. The first
    /// prompt would drop the date it had above it, since the one before it is now close: a row
    /// above the reader would go, which the reader sees move. A date once shown stays.
    @Test(arguments: [TranscriptFolding.summarized, .workedFor])
    func prependingACloseOlderPageKeepsTheRowsAboveTheReader(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: chat(turns: 4, from: 1_000, tag: "tail"), turns: [], seq: 1, hasMore: true)
        let before = thread.rows(folding).map(\.id)

        thread.prependHistory(items: [prompt("near-q", 1_010), reply("near-qa", 1_011)], hasMore: false)

        let after = thread.rows(folding).map(\.id)
        #expect(Array(after.suffix(before.count)) == before, "ids held before the page: \(before.filter { !after.contains($0) })")
    }

    // MARK: 4. trim, then the trimmed page comes back

    /// A chat no window shows is trimmed to its last page; when it's scrolled back, the page let go
    /// is prepended again. The rows are the same as before the trim, and the chat says more is held.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor])
    func trimmingThenPrependingTheTrimmedPageRestoresTheRows(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        let items = chat(turns: 6)
        thread.loadHistory(items: items, turns: [], seq: 1)
        let before = thread.rows(folding)

        thread.trim(toLast: 7)
        #expect(thread.items.map(\.id) == items.suffix(7).map(\.id))
        #expect(thread.hasMoreHistory, "a trimmed chat must say older items are held back")

        thread.prependHistory(items: Array(items.dropLast(7)), hasMore: false)

        #expect(thread.items.map(\.id) == items.map(\.id))
        #expect(thread.rows(folding).map(\.id) == before.map(\.id))
        #expect(thread.rows(folding) == before)
    }

    // MARK: 5. random interleavings

    /// How often the walk asks for the rows, and in which folding.
    enum Asking: Sendable { case everyStep, nowAndThen, switchingFolding }

    /// Incremental rows equal a full refold after any interleaving of what a live chat does. Seeded,
    /// so a failure names the seed and step to replay.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor], [UInt64(1), 7, 42, 2026])
    func randomInterleavingsFoldAsAllAtOnce(_ folding: TranscriptFolding, seed: UInt64) {
        walk(folding, seed: seed, asking: .everyStep)
    }

    /// Asked for only now and then, the rows fold again from the earliest change since.
    @Test(arguments: [TranscriptFolding.summarized, .workedFor], [UInt64(3), 11])
    func askedNowAndThenTheyFoldAsAllAtOnce(_ folding: TranscriptFolding, seed: UInt64) {
        walk(folding, seed: seed, asking: .nowAndThen)
    }

    /// A change of Tool Calls setting folds everything its way; the previous folding isn't kept.
    @Test(arguments: [UInt64(5), 13])
    func switchingFoldingFoldsAsAllAtOnce(seed: UInt64) {
        walk(.summarized, seed: seed, asking: .switchingFolding)
    }

    private func write(_ id: String, _ minutes: Double, parent: String? = nil) -> Item {
        .toolCall(Item.ToolCall(id: id, parentToolUseId: parent, createdAt: at(minutes), name: "Write", kind: .fileWrite,
                                input: ["file_path": .string("/repo/\(id).swift"), "content": "a\nb\n"], status: .completed)
            .withComparedEdit)
    }

    /// A chat's life at random: turns that complete or are interrupted, calls, edits and writes,
    /// replies streamed, reasoning, a subagent's own calls, replies and edits, background commands,
    /// subagents and their edits finishing after their turn, a finished call updated to failed, a
    /// synthetic prompt, a prompt with no time, notices and errors, trims, older pages and reloads.
    private func walk(_ base: TranscriptFolding, seed: UInt64, asking: Asking) {
        var rng = StabilityRNG(seed: seed)
        let thread = ThreadModel(id: threadID)
        var seq = 1
        var clock = 1_000.0          // minutes of the newest item
        var older = -20_000.0        // minutes of the oldest item held back
        var counter = 0
        var turnOpen = false
        var turnID = ""
        var openReply: String?
        var subagents: [String] = [] // running subagents
        var later: [Item] = []       // started, finishing whenever: background commands, subagents and their edits
        var finished: [(id: String, at: Double)] = []
        var reached = Set<String>()  // dates, a turn's edits of several files, Worked For
        var step = 0

        func nextID(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }
        func send(_ n: (Int) -> ServerNotification) { seq += 1; thread.apply(n(seq)) }
        func started(_ item: Item) { send { .itemStarted(.init(threadId: threadID, seq: $0, item: item)) } }
        func completed(_ item: Item) { send { .itemCompleted(.init(threadId: threadID, seq: $0, item: item)) } }
        func endTurn(_ status: TurnStatus = .completed) {
            if let id = openReply {
                completed(reply(id, clock, text: "Done."))
                openReply = nil
            }
            send { .turnCompleted(.init(threadId: threadID, seq: $0, turn: Turn(id: turnID, status: status, startedAt: 0))) }
            send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .idle)) }
            turnOpen = false
        }
        /// A streamed delta leaves the rows as they were: each row draws its reply's text from the
        /// item's box, so only the ids are compared after one, and the reply being streamed into is
        /// compared without its text (a subagent's step, after a delta, folds nothing again).
        /// A prompt that once had its date keeps it, which folding from scratch can't know: dates
        /// are compared apart, the held rows having at least every date the scratch fold has.
        func undated(_ rows: [TranscriptRow]) -> [TranscriptRow] {
            rows.compactMap { row -> TranscriptRow? in
                switch row {
                case .dateSeparator:
                    return nil
                case .item(.agentMessage(var streaming)) where streaming.id == openReply:
                    streaming.text = ""
                    return .item(.agentMessage(streaming))
                case .turnWork(let id, let rows, let durationMs):
                    return .turnWork(id: id, rows: undated(rows), durationMs: durationMs)
                default:
                    return row
                }
            }
        }
        func dates(_ rows: [TranscriptRow]) -> Set<String> {
            Set(rows.compactMap { if case .dateSeparator = $0 { $0.id } else { nil } })
        }
        func check(_ name: String, deltaOnly: Bool = false, always: Bool = false) {
            if asking == .nowAndThen, !always, step % 4 != 0 { return }
            let folding = asking == .switchingFolding ? foldings[step % foldings.count] : base
            let expected = rowsFromScratch(thread, folding)
            let held = thread.rows(folding)
            #expect(dates(expected).isSubset(of: dates(held)), "dates, seed \(seed), \(folding), after \(name)")
            if asking == .switchingFolding { #expect(thread.foldingsHeld == [folding], "seed \(seed), after \(name)") }
            for row in held {
                switch row {
                case .dateSeparator: reached.insert("dates")
                case .turnEdits(let edits) where edits.files.count > 1: reached.insert("edits")
                case .turnWork: reached.insert("worked for")
                default: break
                }
            }
            if deltaOnly {
                #expect(undated(held).map(\.id) == undated(expected).map(\.id), "ids, seed \(seed), \(folding), after \(name)")
                return
            }
            #expect(undated(held) == undated(expected), "seed \(seed), \(folding), after \(name)")
            #expect(thread.prompts(folding) == TranscriptPrompt.list(in: expected), "prompts, seed \(seed), after \(name)")
        }

        thread.loadHistory(items: chat(turns: 3, tag: "base"), turns: [], seq: seq, hasMore: true)
        check("first page", always: true)

        for n in 0..<200 {
            step = n
            clock += rng.below(4) == 0 ? 90 : 1
            let name: String
            switch rng.below(18) {
            case 0, 1:
                name = "turn"
                if turnOpen { endTurn() }
                send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .running)) }
                turnID = nextID("t")
                send { .turnStarted(.init(threadId: threadID, seq: $0, turn: Turn(id: turnID, status: .inProgress, startedAt: 0))) }
                started(prompt(nextID("p"), clock))
                turnOpen = true
            case 2:
                name = "call"
                let id = nextID("c")
                started(call(id, clock, status: .running))
                completed(call(id, clock))
                finished.append((id, clock))
            case 3:
                name = "edit"
                completed(edit(nextID("e"), clock, path: "/repo/f\(rng.below(3)).swift"))
            case 4, 5:
                name = "stream"
                guard turnOpen else { continue }
                if openReply == nil {
                    openReply = nextID("a")
                    started(reply(openReply!, clock, text: ""))
                }
                send { .itemAgentMessageDelta(.init(threadId: threadID, seq: $0, itemId: openReply!, delta: "word ")) }
            case 6:
                name = "finish reply"
                if let id = openReply { completed(reply(id, clock, text: "Done.")); openReply = nil }
            case 7:
                name = "end turn"
                if turnOpen { endTurn(rng.below(4) == 0 ? .interrupted : .completed) }
            case 8:
                name = "trim"
                // As `HostConnection` does: only a chat no window shows, idle, with nothing pending.
                guard !turnOpen, thread.items.count > 8 else { continue }
                thread.trim(toLast: 4 + rng.below(20))
            case 9:
                name = "prepend"
                guard thread.hasMoreHistory else { continue }
                let count = 1 + rng.below(4)
                let base = older - 3 * Double(count)
                let page = (0..<count).map { i -> Item in
                    i == 0 ? prompt(nextID("o"), base)
                        : rng.below(3) == 0 ? edit(nextID("oe"), base + 3 * Double(i)) : call(nextID("oc"), base + 3 * Double(i))
                }
                older = base
                thread.prependHistory(items: page, hasMore: rng.below(2) == 0)
            case 10:
                name = "subagent"
                let id = nextID("s")
                started(subagent(id, clock, status: .running))
                subagents.append(id)
                later.append(subagent(id, clock, status: .completed))
            case 11:
                name = "subagent's step"
                guard !subagents.isEmpty else { continue }
                let parent = subagents[rng.below(subagents.count)]
                switch rng.below(3) {
                case 0:
                    let id = nextID("sc")
                    started(call(id, clock, kind: .fileRead, status: .running, parent: parent))
                    completed(call(id, clock, kind: .fileRead, parent: parent))
                case 1:
                    let id = nextID("sa")
                    started(reply(id, clock, text: "", parent: parent))
                    completed(reply(id, clock, text: "Found it.", parent: parent))
                default:
                    let id = nextID("se")
                    started(edit(id, clock, status: .running, parent: parent))
                    later.append(edit(id, clock, parent: parent))
                }
            case 12:
                name = "finish later"
                guard !later.isEmpty else { continue }
                let item = later.remove(at: rng.below(later.count))
                completed(item)
                subagents.removeAll { $0 == item.id }
                if case .toolCall(let done) = item, done.kind == .bash { finished.append((done.id, (done.createdAt - t0) / 60_000)) }
            case 13:
                name = "background command"
                let id = nextID("bg")
                started(call(id, clock, status: .running))
                later.append(call(id, clock))
            case 14:
                name = "reasoning"
                started(.reasoning(.init(id: nextID("r"), createdAt: at(clock), text: "Thinking it over")))
            case 15:
                name = "update"
                guard !finished.isEmpty else { continue }
                let done = finished[rng.below(finished.count)]
                send { .itemUpdated(.init(threadId: threadID, seq: $0, item: call(done.id, done.at, status: .failed))) }
            case 16:
                name = "aside"
                switch rng.below(4) {
                case 0: started(prompt(nextID("sp"), clock, synthetic: true))
                case 1: started(.userMessage(.init(id: nextID("tp"), createdAt: 0, content: [.text(.init(text: "Timeless"))])))
                case 2: started(.notice(.init(id: nextID("n"), createdAt: at(clock), kind: "info", text: "Compacted")))
                default: started(.error(.init(id: nextID("x"), createdAt: at(clock), message: "Overloaded")))
                }
            default:
                name = "write"
                completed(write(nextID("w"), clock))
            }
            if rng.below(6) == 0 {
                thread.loadHistory(items: thread.items, turns: thread.turns, seq: seq, hasMore: thread.hasMoreHistory)
                check("step \(n) \(name), then reload")
            } else {
                check("step \(n) \(name)", deltaOnly: name == "stream")
            }
        }
        check("the end", always: true)
        // The walk reached everything it's meant to: dates, a turn's edits, Worked For.
        if asking == .everyStep {
            #expect(reached.isSuperset(of: ["dates", "edits"]), "seed \(seed) reached only \(reached)")
            if base == .workedFor { #expect(reached.contains("worked for"), "seed \(seed) reached only \(reached)") }
        }
    }

    // MARK: 6. a streaming reply

    /// A reply's row keeps its id from its first delta to its completion, and through the turn's
    /// end, where its work folds into a group or a Worked For row.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor])
    func aStreamingRepliesRowIdHoldsThroughTheTurnsEnd(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: chat(turns: 2), turns: [], seq: 1)
        var seq = 1
        func send(_ n: (Int) -> ServerNotification) { seq += 1; thread.apply(n(seq)) }
        func held(_ step: String) {
            #expect(thread.rows(folding).contains { $0.id == "live-a" }, "live-a lost after \(step), \(folding)")
        }

        send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .running)) }
        send { .turnStarted(.init(threadId: threadID, seq: $0, turn: Turn(id: "live-t", status: .inProgress, startedAt: 0))) }
        send { .itemStarted(.init(threadId: threadID, seq: $0, item: prompt("live-p", 500))) }
        for id in ["live-c1", "live-c2"] {
            send { .itemStarted(.init(threadId: threadID, seq: $0, item: call(id, 501, status: .running))) }
            send { .itemCompleted(.init(threadId: threadID, seq: $0, item: call(id, 501))) }
        }
        send { .itemCompleted(.init(threadId: threadID, seq: $0, item: edit("live-e1", 502))) }
        send { .itemStarted(.init(threadId: threadID, seq: $0, item: reply("live-a", 503, text: ""))) }
        held("its first draw")
        send { .itemAgentMessageDelta(.init(threadId: threadID, seq: $0, itemId: "live-a", delta: "The ")) }
        held("the first delta")
        send { .itemAgentMessageDelta(.init(threadId: threadID, seq: $0, itemId: "live-a", delta: "answer.")) }
        held("a second delta")
        send { .itemCompleted(.init(threadId: threadID, seq: $0, item: reply("live-a", 503, text: "The answer."))) }
        held("its completion")
        send { .turnCompleted(.init(threadId: threadID, seq: $0, turn: Turn(id: "live-t", status: .completed, startedAt: 0))) }
        send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .idle)) }
        held("the turn's end")
    }

    // MARK: 7. date separators and the clock

    /// A date separator's id is its prompt's, never the time: the same prompt keeps its separator's
    /// id as the clock moves on, and the rows don't depend on when they're asked for.
    @Test func dateSeparatorIdsFollowThePromptNotTheClock() throws {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: chat(turns: 6), turns: [], seq: 1)
        let rows = thread.rows(.summarized)
        let separators = rows.compactMap { row -> String? in
            if case .dateSeparator = row { row.id } else { nil }
        }
        #expect(!separators.isEmpty)
        #expect(separators.allSatisfy { $0.hasPrefix("date-") })
        #expect(Set(separators).count == separators.count)
        // Asked again with nothing changed, the same rows, however much time has passed.
        #expect(thread.rows(.summarized) == rows)
    }
}

/// The rows as they were made before: every item folded and decorated at once.
@MainActor
func rowsFromScratch(_ thread: ThreadModel, _ folding: TranscriptFolding) -> [TranscriptRow] {
    let items = thread.items
    let top = items.filter { $0.parentToolUseId == nil }
    let running = thread.isRunning
    let folded = foldTranscriptRows(top, folding: folding, lastTurnRunning: running)
    return decorateTranscriptRows(folded, dates: DateSeparators.prompts(in: top),
                                  edits: editedFiles(in: items, lastTurnRunning: running,
                                                     totals: Dictionary(thread.turns.compactMap { t in t.edits.map { (t.id, $0) } },
                                                                        uniquingKeysWith: { _, b in b })))
}

/// A seeded generator (SplitMix64), so a random walk replays the same way every run.
private struct StabilityRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
