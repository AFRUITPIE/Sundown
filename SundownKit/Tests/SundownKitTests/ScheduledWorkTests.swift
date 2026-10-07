import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// Scheduled jobs and goals, worked out from the chat's items as the daemon sends them for a
/// /loop and a /goal (the loop-goal capture, Claude Code 2.1.291).
@MainActor
@Suite
struct ScheduledWorkTests {
    private let prompt = "reply with the current time in one short line"
    private let condition = "notes.md in this directory has no spelling mistakes"

    private func user(_ id: String, _ text: String, at t: Double = 1) -> Item {
        .userMessage(.init(id: id, createdAt: t, content: [.text(.init(text: text))]))
    }

    private func wakeup(_ id: String, _ text: String? = nil, at t: Double = 1) -> Item {
        .userMessage(.init(id: id, createdAt: t, content: [.text(.init(text: text ?? prompt))], synthetic: true, origin: "wakeup"))
    }

    private func cronCreate(_ id: String = "create", job: String = "6db9ae9a", recurring: Bool = true, prompt: String? = nil,
                            status: ToolStatus = .completed, withOutput: Bool = true) -> Item {
        let p = prompt ?? self.prompt
        return .toolCall(.init(id: id, createdAt: 1, name: "CronCreate", kind: .schedule,
                               input: ["cron": "*/1 * * * *", "prompt": .string(p), "recurring": .bool(recurring)], status: status,
                               outputText: "Scheduled \(recurring ? "recurring" : "one-shot") job \(job) (Every minute). Session-only.",
                               output: withOutput ? ["id": .string(job), "humanSchedule": "Every minute", "recurring": .bool(recurring), "durable": false] : nil))
    }

    private func cronDelete(_ job: String = "6db9ae9a") -> Item {
        .toolCall(.init(id: "delete-\(job)", createdAt: 1, name: "CronDelete", kind: .schedule, input: ["id": .string(job)],
                        status: .completed, outputText: "Cancelled job \(job).", output: ["id": .string(job)]))
    }

    private func wakeupCall(_ id: String, prompt: String = "/loop check the deploy", next: Double = 5000, stop: Bool = false) -> Item {
        .toolCall(.init(id: id, createdAt: 1, name: "ScheduleWakeup", kind: .schedule,
                        input: stop ? ["stop": true] : ["delaySeconds": 270, "reason": "watching CI", "prompt": .string(prompt), "noop": false],
                        status: .completed, output: stop ? ["scheduledFor": 0, "stopped": true] : ["scheduledFor": .number(next), "clampedDelaySeconds": 270]))
    }

    private func goal(_ id: String, _ event: GoalEvent, reason: String? = nil, iterations: Double? = nil, at t: Double = 1) -> Item {
        .notice(.init(id: id, createdAt: t, kind: "goal", text: "", goal: .init(condition: condition, event: event, reason: reason, iterations: iterations)))
    }

    private let cron = SessionCron(id: "6db9ae9a", schedule: "*/1 * * * *", recurring: true, prompt: "reply with the current time in one short line")

    /// The capture's /loop: made from a /loop prompt, fired twice, then deleted.
    @Test func aLoopsJobIsMadeFiredAndDeleted() throws {
        let items = [user("p", "/loop 1m \(prompt)"), cronCreate(), wakeup("w1", at: 60), wakeup("w2", at: 120)]
        var work = ScheduledWork.make(from: items, liveness: .live(crons: [cron], turnRunning: false))
        let run = try #require(work.schedules.first)
        #expect(work.schedules.count == 1)
        #expect(run.jobID == "6db9ae9a")
        #expect(run.fromLoop)
        #expect(run.humanSchedule == "Every minute")
        #expect(run.firings == [60, 120])
        #expect(run.state == .scheduled)
        #expect(work.loopWakeups == ["w1", "w2"])

        work = ScheduledWork.make(from: items + [user("s", "stop the loop"), cronDelete()], liveness: .live(crons: [], turnRunning: false))
        #expect(work.schedules.map(\.state) == [.deleted])
    }

    /// A job made by CronCreate outside a /loop fires with its prompt, and a one-shot is done once fired.
    @Test func aOneShotIsDoneOnceItFires() {
        let items = [user("p", "remind me at noon"), cronCreate(recurring: false, prompt: "check the oven")]
        #expect(ScheduledWork.make(from: items, liveness: .unknown).schedules.first?.state == .scheduled)
        let fired = ScheduledWork.make(from: items + [wakeup("w", "check the oven")], liveness: .unknown)
        #expect(fired.schedules.first?.state == .done)
        #expect(fired.schedules.first?.fromLoop == false)
        #expect(fired.loopWakeups.isEmpty)
    }

    /// What the Stop hook lists says what's still scheduled, once no turn is running: the list is
    /// said at a turn's end, so a job made in the running turn isn't on it yet.
    @Test func theSessionsListSaysWhatStillWakesIt() {
        let items = [user("p", "/loop 1m \(prompt)"), cronCreate()]
        #expect(ScheduledWork.make(from: items, liveness: .live(crons: [], turnRunning: true)).schedules.first?.state == .scheduled)
        #expect(ScheduledWork.make(from: items, liveness: .live(crons: [], turnRunning: false)).schedules.first?.state == .ended)
        #expect(ScheduledWork.make(from: items, liveness: .live(crons: [cron], turnRunning: false)).schedules.first?.state == .scheduled)
        // An older server says nothing: the items alone decide.
        #expect(ScheduledWork.make(from: items, liveness: .live(crons: nil, turnRunning: false)).schedules.first?.state == .scheduled)
        // Session-only, it goes with the session's process.
        #expect(ScheduledWork.make(from: items, liveness: .ended).schedules.first?.state == .ended)
    }

    /// A dynamic /loop is one job whose next wakeup moves on each turn, and ends when a firing turn
    /// schedules no next one, or Claude stops it.
    @Test func aDynamicLoopIsOneJobUntilItStops() {
        var items: [Item] = [user("p", "/loop check the deploy"), wakeupCall("c1", next: 1000)]
        var work = ScheduledWork.make(from: items, liveness: .unknown)
        #expect(work.schedules.count == 1)
        #expect(work.schedules[0].isWakeup && work.schedules[0].fromLoop)
        #expect(work.schedules[0].nextFire == 1000)

        items += [wakeup("w1", "/loop check the deploy", at: 1000), wakeupCall("c2", next: 2000)]
        work = ScheduledWork.make(from: items, liveness: .unknown)
        #expect(work.schedules.count == 1)
        #expect(work.schedules[0].nextFire == 2000)
        #expect(work.schedules[0].state == .scheduled)
        #expect(work.loopWakeups == ["w1"])

        // Fired, and its turn still running: it may yet schedule the next.
        let firing = items + [wakeup("w2", "/loop check the deploy", at: 2000)]
        #expect(ScheduledWork.make(from: firing, liveness: .live(crons: nil, turnRunning: true)).schedules[0].state == .scheduled)
        #expect(ScheduledWork.make(from: firing, liveness: .live(crons: nil, turnRunning: false)).schedules[0].state == .done)

        let stopped = items + [user("s", "stop"), wakeupCall("c3", stop: true)]
        #expect(ScheduledWork.make(from: stopped, liveness: .unknown).schedules[0].state == .deleted)
    }

    /// A call that failed or hasn't come back made no job.
    @Test func onlyAFinishedCallMakesAJob() {
        #expect(ScheduledWork.make(from: [cronCreate(status: .running)], liveness: .unknown).schedules.isEmpty)
        #expect(ScheduledWork.make(from: [cronCreate(status: .denied)], liveness: .unknown).schedules.isEmpty)
        // Its id read from the text when there's no structured answer (history).
        #expect(ScheduledWork.make(from: [cronCreate(withOutput: false)], liveness: .unknown).schedules.first?.jobID == "6db9ae9a")
    }

    /// A prompt the CLI cut at 1000 characters still matches its job.
    @Test func aCutPromptStillMatches() {
        #expect(ScheduledWork.same("abc… [+12 chars]", "abcdefghijklmno"))
        #expect(!ScheduledWork.same("abd… [+12 chars]", "abcdefghijklmno"))
    }

    /// A goal: set, checked and found not met yet (the last reason kept), then met.
    @Test func aGoalCountsItsChecksUntilMet() throws {
        var items = [user("p", "/goal \(condition)"), goal("g", .set)]
        #expect(ScheduledWork.make(from: items, liveness: .unknown).goals.map(\.state) == [.active])
        items += [goal("c1", .notMet, reason: "typo on line 2"), goal("c2", .notMet, reason: "typo on line 3")]
        var g = try #require(ScheduledWork.make(from: items, liveness: .unknown).goals.first)
        #expect(g.misses == 2 && g.checks == 2)
        #expect(g.lastReason == "typo on line 3")
        items += [goal("c3", .met, reason: "fixed", at: 9)]
        g = try #require(ScheduledWork.make(from: items, liveness: .unknown).goals.first)
        #expect(g.state == .met && g.checks == 3 && g.endedAt == 9)
        // A new goal replaces one still active.
        let replaced = ScheduledWork.make(from: [goal("a", .set), goal("b", .set)], liveness: .unknown).goals
        #expect(replaced.map(\.state) == [.cleared, .active])
    }

    /// In the thread: the jobs and goals are Tasks entries of their own, kept as items arrive and
    /// as what wakes the session changes.
    @Test func theThreadListsThemAsTasks() throws {
        let thread = ThreadModel.sampleScheduledWork(finished: false)
        #expect(thread.taskEntries.compactMap(\.schedule).map(\.state) == [.scheduled])
        #expect(thread.taskEntries.compactMap(\.goal).map(\.state) == [.active])
        #expect(thread.scheduledWork.loopWakeups == ["wakeup-1", "wakeup-2"])

        let finished = ThreadModel.sampleScheduledWork(finished: true)
        #expect(finished.taskEntries.compactMap(\.schedule).map(\.state) == [.deleted])
        #expect(finished.taskEntries.compactMap(\.goal).map(\.state) == [.met])

        // The session's process ends, as the daemon says so: the turn cut short, nothing left to
        // wake it, closed. Its job went with it.
        let closing = ThreadModel.sampleScheduledWork(finished: false)
        var turn = try #require(closing.turns.last)
        turn.status = .interrupted
        closing.apply(.turnCompleted(.init(threadId: closing.id, seq: 2, turn: turn)))
        var info = try #require(closing.info)
        info.sessionCrons = []
        closing.apply(.threadUpdated(.init(threadId: closing.id, seq: 3, thread: info)))
        closing.apply(.threadClosed(.init(threadId: closing.id, seq: 4)))
        #expect(closing.taskEntries.compactMap(\.schedule).map(\.state) == [.ended])
    }

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

/// The capture's /loop chat as the daemon serves it from disk (`thread/read` on a followed
/// session: the job made and deleted before the daemon last started).
@MainActor
@Suite
struct ScheduledWorkHistoryTests {
    @Test func aLoopReadFromHistoryIsAScheduleTask() throws {
        let url = try #require(Bundle.module.url(forResource: "loop-history", withExtension: "json", subdirectory: "Fixtures"))
        struct Page: Decodable { let items: [Item]; let turns: [Turn] }
        let page = try JSONDecoder().decode(Page.self, from: Data(contentsOf: url))
        let thread = ThreadModel(id: "74bd0718-b17d-47ab-9b2c-01c0ded4136b")
        thread.loadHistory(items: page.items, turns: page.turns, seq: 1)
        thread.setInfo(.init(threadId: thread.id, status: .notLoaded, cwd: "/private/tmp/wf-scratch", lastSeq: 1))
        let runs = thread.taskEntries.compactMap(\.schedule)
        #expect(runs.count == 1)
        #expect(runs.first?.jobID == "6db9ae9a")
        #expect(runs.first?.fromLoop == true)
        #expect(runs.first?.firings.count == 2)
        #expect(runs.first?.state == .deleted)
    }
}
