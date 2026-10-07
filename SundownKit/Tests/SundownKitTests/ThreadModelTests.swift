import Foundation
import Observation
import Testing
import TetherProtocol
@testable import SundownKit

@MainActor
@Suite
struct ThreadModelTests {
    private let threadID = "thread-under-test"

    private func userMessage(_ text: String, id: String = "u1", synthetic: Bool? = nil) -> Item {
        .userMessage(.init(id: id, createdAt: 0, content: [.text(.init(text: text))], synthetic: synthetic))
    }

    private func started(_ item: Item, seq: Int) -> ServerNotification {
        .itemStarted(.init(threadId: threadID, seq: seq, item: item))
    }

    /// A skill's instructions, which Claude Code puts in the chat as a message of their own right
    /// after the call, belong to the call: neither a message nor a turn of their own, live or read.
    @Test func aSkillsInstructionsGoToItsCall() {
        let skill = Item.toolCall(.init(id: "skill-1", createdAt: 1, name: "Skill", kind: .skill,
                                        input: ["skill": "shadcn"], status: .completed, outputText: "Launching skill: shadcn"))
        let body = userMessage("Base directory for this skill: /x\n\n# shadcn/ui", id: "u2", synthetic: true)
        let after = userMessage("Thanks", id: "u3")

        let live = ThreadModel(id: threadID)
        live.loadHistory(items: [userMessage("Use shadcn")], turns: [], seq: 0)
        live.apply(started(skill, seq: 1))
        live.apply(started(body, seq: 2))
        live.apply(started(after, seq: 3))
        #expect(live.items.map(\.id) == ["u1", "skill-1", "u3"])
        #expect(live.skillBodies["skill-1"]?.hasPrefix("Base directory for this skill") == true)

        let read = ThreadModel(id: threadID)
        read.loadHistory(items: [userMessage("Use shadcn"), skill, body, after], turns: [], seq: 3)
        #expect(read.items.map(\.id) == ["u1", "skill-1", "u3"])
        #expect(read.skillBodies["skill-1"] == live.skillBodies["skill-1"])

        // Anything else synthetic after a call stays a message.
        let other = ThreadModel(id: threadID)
        other.loadHistory(items: [userMessage("Go"), body], turns: [], seq: 1)
        #expect(other.items.count == 2)
    }

    /// Only `started` says what a task is, and a later `updated` patch can leave out its tool call.
    @Test func laterTaskEventsKeepWhatEarlierOnesSaid() {
        let thread = ThreadModel(id: threadID)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "started", taskId: "b1",
                                      toolUseId: "toolu_1", description: "Sleep then echo", data: [:])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 2, event: "updated", taskId: "b1",
                                      status: "completed", data: [:])))

        let task = thread.tasks["b1"]
        #expect(task?.event == "updated")
        #expect(task?.status == "completed")
        #expect(task?.toolUseId == "toolu_1")
        #expect(task?.description == "Sleep then echo")
    }

    @Test func aTaskRunsUntilItsNotificationOrAFinalStatus() {
        let thread = ThreadModel(id: threadID)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "started", taskId: "b1", data: [:])))
        #expect(thread.taskEntries.first?.isTaskRunning == true)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 2, event: "updated", taskId: "b1", status: "stopped", data: [:])))
        #expect(thread.taskEntries.first?.isTaskRunning == false)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 3, event: "started", taskId: "b2", data: [:])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 4, event: "notification", taskId: "b2", data: [:])))
        #expect(thread.taskEntries.first { $0.task?.taskId == "b2" }?.isTaskRunning == false)
    }

    @Test func aFinalStatusSurvivesALaterUpdateWithoutOne() {
        let thread = ThreadModel(id: threadID)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "started", taskId: "b1", toolUseId: "toolu_1",
                                      data: ["task_type": "local_bash"])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 2, event: "updated", taskId: "b1", status: "completed", data: [:])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 3, event: "updated", taskId: "b1", data: ["patch": [:]])))
        #expect(thread.taskEntries.first?.isTaskRunning == false)
        #expect(thread.tasks["b1"]?.data["task_type"]?.stringValue == "local_bash")
    }

    /// The thread's process ended: nothing it ran is running any more, and nothing offers to stop it.
    @Test func closingAThreadSettlesItsTasks() {
        let thread = ThreadModel(id: threadID)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "started", taskId: "b1", toolUseId: "toolu_1",
                                      data: ["task_type": "local_bash"])))
        thread.apply(.taskBackgroundChanged(.init(threadId: threadID, seq: 2, tasks: [["task_id": "b1"]])))
        #expect(thread.taskEntries.first?.isTaskRunning == true)

        thread.apply(.threadClosed(.init(threadId: threadID, seq: 3)))

        #expect(thread.taskEntries.first?.isTaskRunning == false)
        #expect(thread.backgroundTaskIDs.isEmpty)
    }

    @Test func onlyACommandOrAgentCanMoveToTheBackground() {
        let thread = ThreadModel(id: threadID)
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "started", taskId: "b1", toolUseId: "toolu_1",
                                      data: ["task_type": "local_bash"])))
        thread.apply(.taskEvent(.init(threadId: threadID, seq: 2, event: "started", taskId: "w1", toolUseId: "toolu_2",
                                      data: ["task_type": "local_workflow"])))
        #expect(thread.taskEntries.first { $0.task?.taskId == "b1" }?.canMoveToBackground == true)
        #expect(thread.taskEntries.first { $0.task?.taskId == "w1" }?.canMoveToBackground == false)
    }

    @Test func theOpeningPromptNamesAnUnnamedThread() {
        let thread = ThreadModel(id: threadID)
        #expect(thread.title == "New Chat")

        thread.apply(started(userMessage("/compact"), seq: 1))
        thread.apply(started(userMessage("Rebuild the window layout", id: "u2"), seq: 2))

        #expect(thread.title == "/compact")
        #expect(thread.isUnnamed)
    }

    @Test func syntheticMessagesNeverNameAThread() {
        let thread = ThreadModel(id: threadID)

        thread.apply(started(userMessage("Caveat: this message was injected", synthetic: true), seq: 1))
        #expect(thread.title == "New Chat")

        thread.apply(started(userMessage("Rebuild the window layout", id: "u2"), seq: 2))
        #expect(thread.title == "Rebuild the window layout")
    }

    /// The point of storing the title: reading it must not subscribe a view to `items`.
    @Test func streamedDeltasLeaveTheTitleAlone() {
        let thread = ThreadModel(id: threadID)
        thread.apply(started(userMessage("Rebuild the window layout"), seq: 1))
        #expect(thread.title == "Rebuild the window layout")

        let observed = Invalidation()
        // The Tasks inspector's list, too: streamed text is not a task change.
        withObservationTracking { _ = thread.title; _ = thread.taskEntries } onChange: { observed.happened = true }

        thread.apply(started(.agentMessage(.init(id: "a1", createdAt: 0, text: "")), seq: 2))
        for (offset, delta) in ["On ", "it", "."].enumerated() {
            thread.apply(.itemAgentMessageDelta(.init(threadId: threadID, seq: 3 + offset, itemId: "a1", delta: delta)))
        }
        thread.apply(.itemToolCallProgress(.init(threadId: threadID, seq: 6, itemId: "a1", elapsedSeconds: 2)))

        #expect(!observed.happened)
        #expect(thread.title == "Rebuild the window layout")
    }

    /// A streamed token redraws its own row, not the transcript: it changes the item's box, and the
    /// rows only on the first token, which ends "Thinking…".
    @Test func streamedTextGoesToTheItemsBoxNotTheTranscript() throws {
        let thread = ThreadModel(id: threadID)
        thread.apply(started(userMessage("Explain the reducer"), seq: 1))
        thread.apply(.turnStarted(.init(threadId: threadID, seq: 2, turn: .init(id: "t1", status: .inProgress, startedAt: 0))))
        thread.apply(.threadStatusChanged(.init(threadId: threadID, seq: 3, status: .running)))
        thread.apply(started(.agentMessage(.init(id: "a1", createdAt: 0, text: "")), seq: 4))
        let box = thread.box(for: thread.items.last!)
        #expect(thread.isThinking)

        thread.apply(.itemAgentMessageDelta(.init(threadId: threadID, seq: 5, itemId: "a1", delta: "It ")))
        #expect(!thread.isThinking)

        let transcript = Invalidation()
        withObservationTracking { _ = thread.rows; _ = thread.items } onChange: { transcript.happened = true }
        let row = Invalidation()
        withObservationTracking { _ = box.item } onChange: { row.happened = true }
        for (offset, delta) in ["folds ", "items."].enumerated() {
            thread.apply(.itemAgentMessageDelta(.init(threadId: threadID, seq: 6 + offset, itemId: "a1", delta: delta)))
        }

        #expect(!transcript.happened)
        #expect(row.happened)
        let m = try #require(box.item.agentMessage)
        #expect(m.text == "It folds items.")
        // Readers of `items` still see the current text, though they aren't told about each token.
        let stored = try #require(thread.items.last?.agentMessage)
        #expect(stored.text == "It folds items.")
    }

    @Test func aNamedSessionOutranksTheOpeningPrompt() {
        let thread = ThreadModel(id: threadID)
        thread.apply(started(userMessage("Rebuild the window layout"), seq: 1))

        thread.setSummary(.init(threadId: threadID, title: "Window layout rebuild", updatedAt: 1, status: .idle))
        #expect(thread.title == "Window layout rebuild")
        #expect(!thread.isUnnamed)

        thread.apply(.threadUpdated(.init(threadId: threadID, seq: 2, thread: .init(
            threadId: threadID, status: .idle, cwd: "/work/project", title: "Split view rebuild", lastSeq: 2))))
        #expect(thread.title == "Split view rebuild")

        // A rename lands as customTitle on the reloaded summary and wins over both.
        thread.setSummary(.init(threadId: threadID, title: "Window layout rebuild", customTitle: "Layout",
                                updatedAt: 3, status: .idle))
        #expect(thread.title == "Layout")
    }

    @Test func historyAndUnloadKeepTheTitleInStep() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [userMessage("Rebuild the window layout")], turns: [], seq: 10)
        #expect(thread.title == "Rebuild the window layout")

        thread.loadHistory(items: [userMessage("Audit the transcript rows", id: "u9")], turns: [], seq: 20, hasMore: true)
        #expect(thread.title == "Audit the transcript rows")

        thread.prependHistory(items: [userMessage("The first thing I ever asked", id: "u0")], hasMore: false)
        #expect(thread.title == "The first thing I ever asked")

        thread.unload()
        #expect(thread.title == "New Chat")
    }

    private func reply(_ text: String, id: String = "a1", parent: String? = nil) -> Item {
        .agentMessage(.init(id: id, parentToolUseId: parent, createdAt: 0, text: text))
    }

    @Test func taskEntriesFollowTaskEventsWithoutAnyItemChange() {
        let thread = ThreadModel(id: threadID)
        #expect(thread.taskEntries.isEmpty)
        let itemsVersion = thread.itemsVersion

        thread.apply(.taskEvent(.init(threadId: threadID, seq: 1, event: "task_started", taskId: "task-1",
                                      description: "Explore the inspector", status: "running", data: [:])))
        #expect(thread.taskEntries.map(\.id) == ["task:task-1"])
        #expect(thread.taskEntries.first?.isBackgrounded == false)

        thread.apply(.taskBackgroundChanged(.init(threadId: threadID, seq: 2, tasks: [["task_id": "task-1"]])))
        #expect(thread.taskEntries.first?.isBackgrounded == true)

        #expect(thread.itemsVersion == itemsVersion)
    }

    /// Only the reply being streamed into fades its text in: from its start until it completes or
    /// its turn ends, and never a subagent's words. Its deltas don't change which reply it is.
    @Test func theStreamingReplyIsTheOneBeingStreamedInto() {
        let thread = ThreadModel(id: threadID)
        thread.apply(started(userMessage("Go"), seq: 1))
        thread.apply(.turnStarted(.init(threadId: threadID, seq: 2, turn: .init(id: "t1", status: .inProgress, startedAt: 0))))
        thread.apply(started(reply("", id: "s1", parent: "toolu_1"), seq: 3))
        #expect(thread.streamingReplyID == nil)
        thread.apply(started(reply(""), seq: 4))
        #expect(thread.streamingReplyID == "a1")

        let observed = Invalidation()
        withObservationTracking { _ = thread.streamingReplyID } onChange: { observed.happened = true }
        for (offset, delta) in ["It ", "works."].enumerated() {
            thread.apply(.itemAgentMessageDelta(.init(threadId: threadID, seq: 5 + offset, itemId: "a1", delta: delta)))
        }
        #expect(!observed.happened)

        thread.apply(.itemCompleted(.init(threadId: threadID, seq: 7, item: reply("It works."))))
        #expect(thread.streamingReplyID == nil)

        thread.apply(started(reply("", id: "a2"), seq: 8))
        #expect(thread.streamingReplyID == "a2")
        thread.apply(.turnCompleted(.init(threadId: threadID, seq: 9, turn: .init(id: "t1", status: .interrupted, startedAt: 0))))
        #expect(thread.streamingReplyID == nil)
    }

    /// What refreshes after a turn (the Changes pane, the Session pane's context) does so when it ends, not
    /// when the next one starts.
    @Test func theLastFinishedTurnChangesWhenATurnEnds() {
        let thread = ThreadModel(id: threadID)
        #expect(thread.lastFinishedTurn == nil)
        thread.apply(.turnStarted(.init(threadId: threadID, seq: 1, turn: .init(id: "t1", status: .inProgress, startedAt: 0))))
        #expect(thread.lastFinishedTurn == nil)
        thread.apply(.turnCompleted(.init(threadId: threadID, seq: 2, turn: .init(id: "t1", status: .completed, startedAt: 0))))
        let first = thread.lastFinishedTurn
        #expect(first != nil)

        thread.apply(.turnStarted(.init(threadId: threadID, seq: 3, turn: .init(id: "t2", status: .inProgress, startedAt: 0))))
        #expect(thread.lastFinishedTurn == first)
        thread.apply(.turnCompleted(.init(threadId: threadID, seq: 4, turn: .init(id: "t2", status: .failed, startedAt: 0))))
        #expect(thread.lastFinishedTurn != first)
        #expect(thread.lastFinishedTurn != nil)
    }

    /// A chat opened partway through a reply: it came with history, and streams from its next delta.
    @Test func aReplyFromHistoryStreamsFromItsNextDelta() {
        let thread = ThreadModel(id: threadID)
        thread.loadHistory(items: [userMessage("Go"), reply("Half")], turns: [], seq: 2)
        #expect(thread.streamingReplyID == nil)
        thread.apply(.itemAgentMessageDelta(.init(threadId: threadID, seq: 3, itemId: "a1", delta: " done")))
        #expect(thread.streamingReplyID == "a1")
        thread.unload()
        #expect(thread.streamingReplyID == nil)
    }
}

/// Observation's `onChange` is `@Sendable`, so the flag it sets needs a reference to live in.
private final class Invalidation: @unchecked Sendable {
    var happened = false

    @Test func aRewindResultReadsTheSDKsAnswer() {
        let r = RewindResult(["canRewind": true, "filesChanged": ["/a.swift", "/b.swift"], "insertions": 4, "deletions": 1])
        #expect(r.canRewind)
        #expect(r.files == ["/a.swift", "/b.swift"])
        #expect(r.insertions == 4 && r.deletions == 1)
        let no = RewindResult(["canRewind": false, "error": "No checkpoint"])
        #expect(!no.canRewind && no.error == "No checkpoint" && no.files.isEmpty)
    }
}

@Test func aRateLimitReadsTheSDKsInfo() {
    let warning = RateLimit(["status": "allowed_warning", "utilization": 0.85, "resetsAt": 1_790_500_000, "rateLimitType": "five_hour"])
    #expect(warning.status == .warning)
    #expect(warning.utilization == 0.85)
    #expect(warning.resetsAt == Date(timeIntervalSince1970: 1_790_500_000))
    #expect(warning.name == "5-hour limit")
    // A percentage, and a reset in milliseconds, read the same.
    let rejected = RateLimit(["status": "rejected", "utilization": 100, "resetsAt": 1_790_500_000_000, "rateLimitType": "seven_day"])
    #expect(rejected.status == .rejected && rejected.utilization == 1)
    #expect(rejected.resetsAt == Date(timeIntervalSince1970: 1_790_500_000))
    #expect(rejected.name == "weekly limit")
}

/// Up to 2 is a fraction: 1 is the whole limit, and a little over it is past the limit, not 1%.
@Test func aRateLimitsUtilizationIsAFractionUpToTwo() {
    #expect(RateLimit(["utilization": 1]).utilization == 1)
    #expect(RateLimit(["utilization": 0.01]).utilization == 0.01)
    #expect(RateLimit(["utilization": 1.05]).utilization == 1.05)
    #expect(RateLimit(["utilization": 85]).utilization == 0.85)
}

@Suite
struct RateLimitWarningTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let locale = Locale(identifier: "en_US")
    /// 09:00 UTC on some day.
    private let now = Date(timeIntervalSince1970: TimeInterval(1_790_500_000 / 86_400 * 86_400 + 9 * 3600))

    private func limit(_ status: String, resetsIn: TimeInterval, utilization: Double? = nil, kind: String = "five_hour") -> RateLimit {
        var info: [String: JSONValue] = ["status": .string(status), "rateLimitType": .string(kind),
                                         "resetsAt": .number(now.addingTimeInterval(resetsIn).timeIntervalSince1970)]
        if let utilization { info["utilization"] = .number(utilization) }
        return RateLimit(.object(info))
    }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    @Test func aLimitSaysNothingOnceItHasReset() {
        let reached = limit("rejected", resetsIn: 3600)
        #expect(reached.warning(now: now, calendar: calendar, locale: locale) != nil)
        #expect(reached.warning(now: now.addingTimeInterval(3601), calendar: calendar, locale: locale) == nil)
        #expect(limit("allowed", resetsIn: 3600).warning(now: now, calendar: calendar, locale: locale) == nil)
    }

    @Test func aResetTodaySaysTheTime() {
        let reset = now.addingTimeInterval(2 * 3600)
        let text = limit("rejected", resetsIn: 2 * 3600).warning(now: now, calendar: calendar, locale: locale)
        #expect(text == "You’ve reached your 5-hour limit. It resets at \(clock(reset)).")
    }

    @Test func aLaterResetSaysTheDay() {
        let tomorrow = limit("allowed_warning", resetsIn: 20 * 3600, utilization: 0.9).warning(now: now, calendar: calendar, locale: locale)
        #expect(tomorrow == "You’ve used 90% of your 5-hour limit. It resets tomorrow at \(clock(now.addingTimeInterval(20 * 3600))).")

        let weekly = limit("rejected", resetsIn: 3 * 86_400, kind: "seven_day").warning(now: now, calendar: calendar, locale: locale)
        let weekday = now.addingTimeInterval(3 * 86_400).formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        #expect(weekly == "You’ve reached your weekly limit. It resets on \(weekday) at \(clock(now.addingTimeInterval(3 * 86_400))).")

        let far = limit("rejected", resetsIn: 10 * 86_400, kind: "seven_day").warning(now: now, calendar: calendar, locale: locale)
        #expect(far?.contains(" on ") == true && far?.contains(weekday) == false)
    }

    @Test func pastTheLimitReadsAsAllOfIt() {
        let text = limit("allowed_warning", resetsIn: 3600, utilization: 1.05).warning(now: now, calendar: calendar, locale: locale)
        #expect(text?.hasPrefix("You’ve used 100% of your 5-hour limit.") == true)
    }
}

@MainActor
@Test func aSuggestedTaskIsKeptUntilStartedOrDismissed() {
    let thread = ThreadModel(id: "t")
    thread.apply(.threadTaskSuggested(.init(threadId: "t", seq: 1, title: "Update the docs", prompt: "Document the new API", cwd: "/repo")))
    thread.apply(.threadTaskSuggested(.init(threadId: "t", seq: 2, title: "Add tests", prompt: "Cover the parser")))
    #expect(thread.suggestedTasks.map(\.title) == ["Update the docs", "Add tests"])
    #expect(thread.suggestedTasks[0].cwd == "/repo")
    thread.dismissSuggestedTask(thread.suggestedTasks[0].id)
    #expect(thread.suggestedTasks.map(\.title) == ["Add tests"])
}
