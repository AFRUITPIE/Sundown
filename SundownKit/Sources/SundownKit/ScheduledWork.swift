import Foundation
import TetherProtocol

/// A job that wakes the chat later: a CronCreate (a /loop with an interval makes one), or a dynamic
/// /loop's ScheduleWakeup, as the Tasks tab lists it. Worked out from the chat's items — the call
/// that made it, the wakeups it fired (`origin: wakeup`), the call that deleted it — and, while the
/// daemon runs the chat, from what its Stop hook last said will wake it (`ThreadInfo.sessionCrons`).
public struct ScheduleRun: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Waiting to fire, or firing now.
        case scheduled
        /// Fired its last time: a one-shot job, or a dynamic /loop that didn't schedule another.
        case done
        /// Deleted (CronDelete), or a /loop stopped.
        case deleted
        /// Gone without being deleted: its session's process ended (jobs are session-only), or it expired.
        case ended
    }

    /// The call that made it.
    public let id: String
    /// The CLI's id for it, from CronCreate's answer; a wakeup's isn't said.
    public var jobID: String?
    /// What it fires with.
    public var prompt: String
    /// Set up by /loop: the turn's prompt was a /loop, or it's a dynamic /loop's wakeup.
    public var fromLoop: Bool
    /// A dynamic /loop's next wakeup (ScheduleWakeup), rather than a cron job.
    public var isWakeup: Bool
    public var recurring: Bool
    /// A cron expression, in the host's local time.
    public var cron: String?
    /// How Claude Code says when it fires: "Every minute".
    public var humanSchedule: String?
    /// When it fires next, ms since 1970, when known (a wakeup says).
    public var nextFire: Double?
    /// Kept on disk by Claude Code, so it outlives the session's process.
    public var durable: Bool
    /// When it was made, ms since 1970.
    public var createdAt: Double
    /// When it fired, ms since 1970, each wakeup's.
    public var firings: [Double] = []
    /// The wakeup items it fired, by id.
    public var wakeupIDs: [String] = []
    public var state: State = .scheduled

    /// What the Tasks tab calls it: the prompt it fires with, or /loop for an autonomous one.
    public var title: String {
        prompt.hasPrefix("<<autonomous-loop") || prompt.isEmpty ? "/loop" : prompt
    }
}

/// A /goal, from the goal notices: set, each check that found it not met yet, and how it ended.
public struct GoalRun: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case active, met, failed, cleared }

    /// The notice that set it.
    public let id: String
    public var condition: String
    public var setAt: Double
    /// Checks that found it not met yet.
    public var misses = 0
    /// What the last check said: why it wasn't met yet, or why it was.
    public var lastReason: String?
    /// How many checks it took, when Claude Code said (on met and failed).
    public var iterations: Int?
    public var endedAt: Double?
    public var state: State = .active

    /// Checks so far: the misses, and the one that met it or found it couldn't be.
    public var checks: Int { iterations ?? misses + (state == .met || state == .failed ? 1 : 0) }
}

/// The chat's scheduled jobs and goals, worked out from its items. Pure, so it's tested without a thread.
public struct ScheduledWork: Equatable, Sendable {
    public var schedules: [ScheduleRun] = []
    public var goals: [GoalRun] = []
    /// The wakeups that a /loop's job fired, by item id: they read "Woke up for /loop".
    public var loopWakeups: Set<String> = []

    public init() {}

    /// Whether the session's process is known to be running, and what will wake it.
    public enum Liveness: Equatable, Sendable {
        /// The daemon runs it: `crons` is what its Stop hook last said (nil from an older server).
        case live(crons: [SessionCron]?, turnRunning: Bool)
        /// Its process has ended, and its session-only jobs with it.
        case ended
        /// Not run here: another client may be running it, so nothing is assumed.
        case unknown
    }

    /// Whether an item says anything about scheduled work: a schedule call of the chat's own, a
    /// wakeup, a goal notice, or a /loop prompt (whose jobs are the loop's).
    public static func concerns(_ item: Item) -> Bool {
        guard item.parentToolUseId == nil else { return false }
        switch item {
        case .toolCall(let call): return call.kind == .schedule
        case .userMessage(let m):
            if m.origin == "wakeup" { return true }
            guard m.synthetic != true, case .text(let t)? = m.content.first else { return false }
            return t.text.hasPrefix("/loop")
        case .notice(let n): return n.kind == "goal"
        default: return false
        }
    }

    /// The jobs and goals the items tell of, in the order they were made. `items` are the chat's
    /// own, in order; only those `concerns` picks out matter.
    public static func make(from items: some Sequence<Item>, liveness: Liveness) -> ScheduledWork {
        var work = ScheduledWork()
        var loopPrompt = false
        // A dynamic /loop that just fired: it goes on only if its turn schedules the next wakeup.
        var firing: Int?
        func settleFiring() {
            if let i = firing, work.schedules[i].isWakeup, work.schedules[i].state == .scheduled, work.schedules[i].nextFire == nil {
                work.schedules[i].state = .done
            }
            firing = nil
        }
        for item in items where item.parentToolUseId == nil {
            switch item {
            case .userMessage(let m) where m.origin == "wakeup":
                settleFiring()
                let prompt = m.joinedText
                let i = work.schedules.lastIndex { $0.state == .scheduled && Self.same($0.prompt, prompt) }
                    ?? work.schedules.lastIndex { Self.same($0.prompt, prompt) }
                guard let i else {
                    // A job made before the items held (an older page): known only by its firing.
                    var run = ScheduleRun(id: "wakeup:\(m.id)", prompt: prompt, fromLoop: prompt.hasPrefix("/loop"),
                                          isWakeup: false, recurring: true, durable: false, createdAt: m.createdAt)
                    run.firings = [m.createdAt]
                    run.wakeupIDs = [m.id]
                    if run.fromLoop { work.loopWakeups.insert(m.id) }
                    work.schedules.append(run)
                    continue
                }
                work.schedules[i].firings.append(m.createdAt)
                work.schedules[i].wakeupIDs.append(m.id)
                if work.schedules[i].fromLoop { work.loopWakeups.insert(m.id) }
                if work.schedules[i].isWakeup {
                    // Its wakeup is spent; the turn it starts schedules the next, or the loop ends.
                    work.schedules[i].nextFire = nil
                    firing = i
                } else if !work.schedules[i].recurring, work.schedules[i].state == .scheduled {
                    work.schedules[i].state = .done
                }
                loopPrompt = false
            case .userMessage(let m):
                guard m.synthetic != true else { continue }
                settleFiring()
                loopPrompt = m.joinedText.hasPrefix("/loop")
            case .toolCall(let call) where call.kind == .schedule:
                guard call.status == .completed, call.isError != true else { continue }
                apply(call, to: &work, loopPrompt: loopPrompt, firing: &firing)
            case .notice(let n) where n.kind == "goal":
                guard let goal = n.goal else { continue }
                apply(goal, notice: n, to: &work)
            default: break
            }
        }
        // A firing turn still running may yet schedule the next wakeup.
        if case .live(_, true) = liveness {} else { settleFiring() }
        settle(&work, liveness: liveness)
        return work
    }

    private static func apply(_ call: Item.ToolCall, to work: inout ScheduledWork, loopPrompt: Bool, firing: inout Int?) {
        let input = call.input
        let output = call.output ?? .null
        switch call.name {
        case "CronCreate":
            let text = call.outputText ?? ""
            let recurring = input["recurring"]?.boolValue ?? output["recurring"]?.boolValue ?? !text.contains("one-shot")
            var run = ScheduleRun(
                id: call.id,
                jobID: output["id"]?.stringValue ?? Self.match(#"job ([0-9A-Za-z_-]+)"#, in: text),
                prompt: input["prompt"]?.stringValue ?? "",
                fromLoop: loopPrompt,
                isWakeup: false,
                recurring: recurring,
                cron: input["cron"]?.stringValue,
                humanSchedule: output["humanSchedule"]?.stringValue ?? Self.match(#"job [0-9A-Za-z_-]+ \(([^)]+)\)"#, in: text),
                durable: output["durable"]?.boolValue ?? input["durable"]?.boolValue ?? false,
                createdAt: call.createdAt)
            if run.humanSchedule == run.cron { run.humanSchedule = nil }
            work.schedules.append(run)
        case "CronDelete":
            guard let id = input["id"]?.stringValue ?? output["id"]?.stringValue else { return }
            for i in work.schedules.indices where work.schedules[i].jobID == id && work.schedules[i].state == .scheduled {
                work.schedules[i].state = .deleted
            }
        case "ScheduleWakeup":
            if input["stop"]?.boolValue == true || output["stopped"]?.boolValue == true {
                for i in work.schedules.indices where work.schedules[i].isWakeup && work.schedules[i].state == .scheduled {
                    work.schedules[i].state = .deleted
                }
                firing = nil
                return
            }
            let prompt = input["prompt"]?.stringValue ?? ""
            let next = output["scheduledFor"]?.doubleValue
            // Each wakeup replaces the last: one loop, its next wakeup moving on.
            if let i = work.schedules.lastIndex(where: { $0.isWakeup && $0.state == .scheduled && Self.same($0.prompt, prompt) }) {
                work.schedules[i].nextFire = next.flatMap { $0 > 0 ? $0 : nil }
                if next == 0 { work.schedules[i].state = .done }
                if firing == i { firing = nil }
                return
            }
            var run = ScheduleRun(id: call.id, prompt: prompt, fromLoop: true, isWakeup: true, recurring: false,
                                  nextFire: next.flatMap { $0 > 0 ? $0 : nil }, durable: false, createdAt: call.createdAt)
            // Aged out: the CLI scheduled nothing.
            if next == 0 { run.state = .done }
            work.schedules.append(run)
        default: break
        }
    }

    private static func apply(_ goal: GoalNotice, notice: Item.Notice, to work: inout ScheduledWork) {
        let active = work.goals.lastIndex { $0.state == .active }
        switch goal.event {
        case .set:
            // A new goal replaces the one before.
            if let active {
                work.goals[active].state = .cleared
                work.goals[active].endedAt = notice.createdAt
            }
            work.goals.append(GoalRun(id: notice.id, condition: goal.condition, setAt: notice.createdAt))
        default:
            // A check of a goal set before the items held still counts, as a goal of its own.
            let i = active ?? {
                work.goals.append(GoalRun(id: notice.id, condition: goal.condition, setAt: notice.createdAt))
                return work.goals.count - 1
            }()
            if let reason = goal.reason { work.goals[i].lastReason = reason }
            if let n = goal.iterations { work.goals[i].iterations = Int(n) }
            switch goal.event {
            case .notMet: work.goals[i].misses += 1
            case .met: work.goals[i].state = .met
            case .failed: work.goals[i].state = .failed
            case .cleared: work.goals[i].state = .cleared
            default: break
            }
            if work.goals[i].state != .active { work.goals[i].endedAt = notice.createdAt }
        }
    }

    /// What the session says now: a job its Stop hook no longer lists has gone (once no turn is
    /// running, since the list is said at a turn's end); one whose process has ended went with it.
    private static func settle(_ work: inout ScheduledWork, liveness: Liveness) {
        for i in work.schedules.indices where work.schedules[i].state == .scheduled {
            let run = work.schedules[i]
            switch liveness {
            case .live(let crons?, false):
                let listed = crons.contains { cron in
                    if let id = run.jobID { return cron.id == id }
                    return cron.recurring == run.recurring && same(cron.prompt, run.prompt)
                }
                if !listed { work.schedules[i].state = run.recurring ? .ended : .done }
            case .ended where !run.durable:
                work.schedules[i].state = .ended
            default: break
            }
        }
    }

    /// The same prompt, allowing for the CLI's cut at 1000 characters ("… [+N chars]").
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func cut(_ s: String) -> String? {
            guard let r = s.range(of: #"… \[\+\d+ chars\]$"#, options: .regularExpression) else { return nil }
            return String(s[..<r.lowerBound])
        }
        if let c = cut(a) { return b.hasPrefix(c) }
        if let c = cut(b) { return a.hasPrefix(c) }
        return false
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(text[r])
        // The first group: what the pattern's parentheses hold.
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: found, range: NSRange(found.startIndex..., in: found)), m.numberOfRanges > 1,
              let g = Range(m.range(at: 1), in: found) else { return nil }
        return String(found[g])
    }
}

private extension Item.UserMessage {
    /// The message's text parts, joined.
    var joinedText: String {
        content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined(separator: "\n\n")
    }
}
