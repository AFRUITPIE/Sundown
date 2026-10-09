import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// What a bounce or a blank transcript needs from the rows: a reader's rows keep their ids and order
/// when the chat under them reloads, grows, gets an older page, is trimmed and restored, or has a
/// turn end. Each assertion is one property that, if it failed, would move the content under the
/// reader or leave it empty.
@MainActor
@Suite(.serialized)
struct TranscriptStabilityTests {
    private let threadID = "stability"
    /// A Monday morning, in ms, as in `IncrementalRowsTests`.
    private let t0: Double = 1_790_000_000_000
    private let foldings: [TranscriptFolding] = [.summarized, .everyCall, .workedFor]

    // MARK: items

    private func at(_ minutes: Double) -> Double { t0 + minutes * 60_000 }

    private func prompt(_ id: String, _ minutes: Double) -> Item {
        .userMessage(.init(id: id, createdAt: at(minutes), content: [.text(.init(text: "Prompt \(id), with more words after it"))]))
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

    private func subagent(_ id: String, _ minutes: Double, status: ToolStatus) -> Item {
        .toolCall(.init(id: id, createdAt: at(minutes), name: "Task", kind: .subagent,
                        input: ["description": "Look around"], status: status))
    }

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

    /// The rows as they were made before: every item folded and decorated at once.
    private func fromScratch(_ thread: ThreadModel, _ folding: TranscriptFolding) -> [TranscriptRow] {
        let items = thread.items
        let top = items.filter { $0.parentToolUseId == nil }
        let running = thread.isRunning
        let folded = foldTranscriptRows(top, folding: folding, lastTurnRunning: running)
        return decorateTranscriptRows(folded, dates: DateSeparators.prompts(in: top),
                                      edits: turnEdits(in: items, lastTurnRunning: running))
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

    /// Incremental rows equal a full refold after any interleaving of what a live chat does. Seeded,
    /// so a failure names the seed and step to replay.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor], [UInt64(1), 7, 42, 2026])
    func randomInterleavingsFoldAsAllAtOnce(_ folding: TranscriptFolding, seed: UInt64) {
        var rng = StabilityRNG(seed: seed)
        let thread = ThreadModel(id: threadID)
        var seq = 1
        var clock = 1_000.0          // minutes of the newest item
        var older = -20_000.0        // minutes of the oldest item held back
        var counter = 0
        var turnOpen = false
        var turnID = ""
        var openReply: String?

        func nextID(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }
        func send(_ n: (Int) -> ServerNotification) { seq += 1; thread.apply(n(seq)) }
        func started(_ item: Item) { send { .itemStarted(.init(threadId: threadID, seq: $0, item: item)) } }
        func completed(_ item: Item) { send { .itemCompleted(.init(threadId: threadID, seq: $0, item: item)) } }
        func endTurn() {
            if let id = openReply {
                completed(reply(id, clock, text: "Done."))
                openReply = nil
            }
            send { .turnCompleted(.init(threadId: threadID, seq: $0, turn: Turn(id: turnID, status: .completed, startedAt: 0))) }
            send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .idle)) }
            turnOpen = false
        }
        /// A streamed delta leaves the rows as they were: each row draws its reply's text from the
        /// item's box, so only the ids are compared after one (as `IncrementalRowsTests` does).
        /// A prompt that once had its date keeps it, which folding from scratch can't know: dates
        /// are compared apart, the held rows having at least every date the scratch fold has.
        func undated(_ rows: [TranscriptRow]) -> [TranscriptRow] {
            rows.filter { if case .dateSeparator = $0 { false } else { true } }
        }
        func dates(_ rows: [TranscriptRow]) -> Set<String> {
            Set(rows.compactMap { if case .dateSeparator = $0 { $0.id } else { nil } })
        }
        func check(_ step: String, deltaOnly: Bool = false) {
            let expected = fromScratch(thread, folding)
            let held = thread.rows(folding)
            #expect(dates(expected).isSubset(of: dates(held)), "dates, seed \(seed), \(folding), after \(step)")
            if deltaOnly {
                #expect(undated(held).map(\.id) == undated(expected).map(\.id), "ids, seed \(seed), \(folding), after \(step)")
                return
            }
            #expect(undated(held) == undated(expected), "seed \(seed), \(folding), after \(step)")
            #expect(thread.prompts(folding) == TranscriptPrompt.list(in: expected), "prompts, seed \(seed), after \(step)")
        }

        thread.loadHistory(items: chat(turns: 3, tag: "base"), turns: [], seq: seq, hasMore: true)
        check("first page")

        for step in 0..<200 {
            clock += rng.below(4) == 0 ? 90 : 1
            let name: String
            switch rng.below(10) {
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
                if turnOpen { endTurn() }
            case 8:
                name = "trim"
                // As `HostConnection` does: only a chat no window shows, idle, with nothing pending.
                guard !turnOpen, thread.items.count > 8 else { continue }
                thread.trim(toLast: 4 + rng.below(20))
            default:
                name = "prepend"
                guard thread.hasMoreHistory else { continue }
                let n = 1 + rng.below(4)
                let base = older - 3 * Double(n)
                let page = (0..<n).map { i -> Item in
                    i == 0 ? prompt(nextID("o"), base) : call(nextID("oc"), base + 3 * Double(i))
                }
                older = base
                thread.prependHistory(items: page, hasMore: rng.below(2) == 0)
            }
            if rng.below(6) == 0 {
                thread.loadHistory(items: thread.items, turns: thread.turns, seq: seq, hasMore: thread.hasMoreHistory)
                check("step \(step) \(name), then reload")
            } else {
                check("step \(step) \(name)", deltaOnly: name == "stream")
            }
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

    // MARK: 7. what a turn's end changes

    /// Records which row ids go, and which come, when a running turn ends. Not a failure on its
    /// own: a row vanishing at the bottom is a candidate for the bounce. The reply must stay.
    @Test(arguments: [TranscriptFolding.summarized, .everyCall, .workedFor])
    func rowIdsThatChangeWhenATurnEndsAreReported(_ folding: TranscriptFolding) {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: chat(turns: 2), turns: [], seq: 1)
        var seq = 1
        func send(_ n: (Int) -> ServerNotification) { seq += 1; thread.apply(n(seq)) }
        send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .running)) }
        send { .turnStarted(.init(threadId: threadID, seq: $0, turn: Turn(id: "live-t", status: .inProgress, startedAt: 0))) }
        send { .itemStarted(.init(threadId: threadID, seq: $0, item: prompt("live-p", 500))) }
        for id in ["live-c1", "live-c2", "live-c3"] {
            send { .itemStarted(.init(threadId: threadID, seq: $0, item: call(id, 501, status: .running))) }
            send { .itemCompleted(.init(threadId: threadID, seq: $0, item: call(id, 501))) }
        }
        send { .itemCompleted(.init(threadId: threadID, seq: $0, item: edit("live-e1", 502))) }
        send { .itemStarted(.init(threadId: threadID, seq: $0, item: reply("live-a", 503, text: "Working."))) }
        let running = thread.rows(folding).map(\.id)

        send { .turnCompleted(.init(threadId: threadID, seq: $0, turn: Turn(id: "live-t", status: .completed, startedAt: 0))) }
        send { .threadStatusChanged(.init(threadId: threadID, seq: $0, status: .idle)) }
        let done = thread.rows(folding).map(\.id)

        let gone = running.filter { !done.contains($0) }
        let arrived = done.filter { !running.contains($0) }
        print("TURN END \(folding): running last \(running.last ?? "-"), done last \(done.last ?? "-")")
        print("TURN END \(folding): gone \(gone), arrived \(arrived)")
        #expect(done.contains("live-a"), "the reply's row is lost when the turn ends, \(folding)")
    }

    // MARK: 9. a followed chat let go

    /// A followed chat (in the daemon, not loaded) is unloaded when left. Nothing brings its history
    /// back until something calls `open` again, so a window that still shows it, if the count ever
    /// let it go, would stay unavailable.
    @Test func aFollowedChatLeftIsUnloadedUntilItIsOpenedAgain() async throws {
        let daemon = FakeDaemon()
        let items = chat(turns: 10)
        await daemon.script.queue("thread/read", ThreadReadResult(items: items, turns: [], historySeq: 100, hasMore: false))
        await daemon.script.queue("thread/subscribe", ThreadSubscribeResult(
            thread: .init(threadId: threadID, status: .notLoaded, cwd: "/repo", lastSeq: 100), replayed: 0, gap: false))
        let connection = daemon.connection()
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        #expect(thread.isFollowed)
        #expect(thread.historyLoaded)

        connection.leave(thread)
        #expect(!thread.historyLoaded)
        #expect(thread.itemsHeld == 0)

        // A turn ends and the list refreshes, with no open call from a window that shows it.
        await connection.afterTurn()
        #expect(!thread.historyLoaded, "a left, followed chat came back with nothing having asked for it")

        await daemon.script.queue("thread/read", ThreadReadResult(items: items, turns: [], historySeq: 100, hasMore: false))
        await connection.open(thread)
        #expect(thread.historyLoaded)
        #expect(thread.items.map(\.id) == items.map(\.id))
        await connection.disconnect()
    }

    /// An event in flight when a followed chat is let go lands in the emptied model: one item, with
    /// no history under it, shown beside "not loaded". A chat let go drops item events until it's
    /// opened again.
    @Test func anEventAfterLeavingAFollowedChatDoesNotFillItWithOneItem() async throws {
        let daemon = FakeDaemon()
        await daemon.script.queue("thread/read", ThreadReadResult(items: chat(turns: 10), turns: [], historySeq: 100, hasMore: false))
        await daemon.script.queue("thread/subscribe", ThreadSubscribeResult(
            thread: .init(threadId: threadID, status: .notLoaded, cwd: "/repo", lastSeq: 100), replayed: 0, gap: false))
        let connection = daemon.connection()
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        connection.leave(thread)

        daemon.emit("item/started", encoded(ItemStartedNotification(threadId: threadID, seq: 101, item: prompt("late", 900))))
        // A status change after it, which still reaches the chat: once it has, the item was routed too.
        daemon.emit("thread/status/changed", ["threadId": .string(threadID), "seq": 102, "status": "idle"])
        try await eventually { thread.lastSeq == 102 }

        #expect(thread.items.isEmpty, "an unloaded chat holds \(thread.items.map(\.id))")
        #expect(!thread.historyLoaded)
        await connection.disconnect()
    }

    // MARK: 10. date separators and the clock

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

    // MARK: 11. replay gap reload on a reconnect

    /// Two connections to one chat: the first holds its last page and an older page the reader
    /// scrolled to; after a reconnect whose subscription reports a gap, the chat reloads its last
    /// page only, so the older page's rows went. Every row the reader held survives the reload.
    @Test func aGapReconnectKeepsTheOlderRowsTheReaderHeld() async throws {
        let (before, after, _) = try await reconnectAfterOlderPage(gap: true)
        #expect(after.count == before.count, "a gap reload dropped \(before.count - after.count) rows the reader held")
        #expect(Set(before).isSubset(of: Set(after)))
    }

    /// Without a gap, the reconnect keeps everything the chat held (the control for the test above).
    @Test func aReconnectWithoutAGapKeepsEveryRow() async throws {
        let (before, after, _) = try await reconnectAfterOlderPage(gap: false)
        #expect(after == before)
    }

    /// Loads a 120-item chat as its last page of 50 and an older page of 70, then reconnects to the
    /// same daemon state with the subscription reporting `gap`. Returns the row ids before and after.
    private func reconnectAfterOlderPage(gap: Bool) async throws -> ([String], [String], Int) {
        func message(_ n: Int) -> Item {
            n % 10 == 0
                ? .userMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), content: [.text(.init(text: "Prompt \(n)"))]))
                : .agentMessage(.init(id: "m\(n)", createdAt: Double(1_000 + n), text: "Reply \(n)"))
        }
        let all = (0..<120).map(message)
        let tail = Array(all.suffix(50)), head = Array(all.prefix(70))
        let id = threadID
        func subscription(_ gap: Bool) -> ThreadSubscribeResult {
            ThreadSubscribeResult(thread: .init(threadId: id, status: .idle, cwd: "/repo", lastSeq: 200), replayed: 0, gap: gap)
        }

        let first = FakeDaemon()
        await first.script.queue("thread/read", ThreadReadResult(items: tail, turns: [], historySeq: 200, hasMore: true))
        await first.script.queue("thread/subscribe", subscription(false))
        await first.script.queue("thread/read", ThreadReadResult(items: head, turns: [], hasMore: false))

        let second = FakeDaemon()
        if gap {
            await second.script.queue("thread/subscribe", subscription(true))
            // The reload asks for at least as much as the chat held; the daemon answers with that
            // many from the end (here the whole chat).
            await second.script.queue("thread/read", ThreadReadResult(items: all, turns: [], historySeq: 200, hasMore: false))
            await second.script.queue("thread/subscribe", subscription(false))
        } else {
            await second.script.queue("thread/subscribe", subscription(false))
        }

        let transports = StabilityTransports([first, second])
        let connection = HostConnection(host: HostConfig(name: "Fake", kind: .ssh(destination: "fake")),
                                        transportProvider: { _ in await transports.next() })
        await connection.connect()
        let thread = connection.thread(threadID)
        await connection.open(thread)
        await connection.loadOlderHistory(thread)
        let before = thread.rows(.summarized).map(\.id)
        #expect(thread.items.count == 120)

        await connection.reconnect()
        let after = thread.rows(.summarized).map(\.id)
        await connection.disconnect()
        return (before, after, thread.items.count)
    }

    // MARK: test support

    /// Each connection's daemon, in the order the connections are made.
    private actor StabilityTransports {
        private var queued: [any Transport]
        init(_ transports: [any Transport]) { queued = transports }
        func next() -> any Transport { queued.removeFirst() }
    }
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
