import SwiftUI
import SundownKit
import TetherProtocol

/// How a scheduled job reads: in its Tasks row, how often it fires or when next, and once it has
/// stopped, how many times it fired. Pure, so it's tested without a view.
enum ScheduleText {
    /// A row's line under the name, in place of a time.
    static func note(_ task: TaskState, _ schedule: ScheduleTaskInfo) -> String {
        if task.status == .running {
            if let next = schedule.nextFireAt { return "Next at \(time(next))" }
            if let every = schedule.description { return every }
            if let cron = schedule.cron { return cron }
            return "Scheduled"
        }
        return fired(schedule.firedCount)
    }

    /// "Fired 2 times", "Never fired".
    static func fired(_ count: Int) -> String {
        count == 0 ? "Never fired" : String(AttributedString(localized: "Fired ^[\(count) time](inflect: true)").characters)
    }

    /// A time today alone; another day's with its date.
    static func time(_ ms: Double) -> String {
        Format.messageTime(msSinceEpoch: ms)
    }

    /// How it repeats, in words: Claude Code's ("Every minute"), else once.
    static func repeats(_ schedule: ScheduleTaskInfo) -> String {
        if schedule.wakeup { return "When Claude chooses" }
        if !schedule.recurring { return "Once" }
        return schedule.description ?? schedule.cron ?? "Repeatedly"
    }

    /// What became of it, for the detail: the dot says how it stands, this says why.
    static func outcome(_ task: TaskState, _ schedule: ScheduleTaskInfo) -> String? {
        switch task.status {
        case .running, .waiting: return nil
        case .done: return schedule.wakeup ? "The loop ended" : "Fired its last time"
        default:
            if schedule.ended == .sessionEnded { return "Ended with its session" }
            return schedule.fromLoop ? "Loop stopped" : "Deleted"
        }
    }
}

/// How a goal reads: its checks so far.
enum GoalText {
    /// "Not checked yet", "1 check", "3 checks".
    static func checks(_ goal: GoalTaskInfo) -> String {
        let n = goal.checks
        return n == 0 ? "Not checked yet" : String(AttributedString(localized: "^[\(n) check](inflect: true)").characters)
    }

    /// The detail's heading over what the last check said.
    static func reasonTitle(_ task: TaskState) -> String {
        switch task.status {
        case .done: "Why It’s Met"
        case .failed: "Why It Can’t Be Met"
        default: "Why It’s Not Met Yet"
        }
    }

    static func outcome(_ task: TaskState) -> String {
        switch task.status {
        case .done: "Met"
        case .failed: "Can’t be met"
        case .stopped: "Cleared"
        default: "Working toward it"
        }
    }
}

/// A scheduled job on its own, in the Tasks tab's detail: what it fires with, how often, when it
/// fired. Nothing to stop it with: no request of the protocol deletes one (ask Claude to).
struct ScheduleReport: View {
    let task: TaskState
    let schedule: ScheduleTaskInfo

    var body: some View {
        Form {
            Section("Prompt") {
                Text(task.title).textSelection(.enabled)
            }
            Section {
                LabeledContent("Repeats", value: ScheduleText.repeats(schedule))
                if task.status == .running, let next = schedule.nextFireAt {
                    LabeledContent("Next", value: ScheduleText.time(next))
                }
                if let cron = schedule.cron, cron != schedule.description {
                    LabeledContent("Cron") { Text(cron).monospaced().textSelection(.enabled) }
                }
                if let made = task.startedAt {
                    LabeledContent("Scheduled", value: ScheduleText.time(made))
                }
                LabeledContent("Fired", value: ScheduleText.fired(schedule.firedCount))
                if let last = schedule.lastFiredAt {
                    LabeledContent("Last Fired", value: ScheduleText.time(last))
                }
                if let outcome = ScheduleText.outcome(task, schedule) {
                    LabeledContent("Status", value: outcome)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// A goal on its own: its condition, how many checks it has had, and what the last one said.
struct GoalReport: View {
    let task: TaskState
    let goal: GoalTaskInfo

    var body: some View {
        Form {
            Section("Condition") {
                Text(goal.condition).textSelection(.enabled)
            }
            Section {
                LabeledContent("Status", value: GoalText.outcome(task))
                LabeledContent("Checks", value: GoalText.checks(goal))
                if let set = task.startedAt {
                    LabeledContent("Set", value: ScheduleText.time(set))
                }
                if let ended = task.endedAt {
                    LabeledContent(task.status == .done ? "Met" : "Ended", value: ScheduleText.time(ended))
                }
            }
            if let reason = goal.lastCheck?.reason {
                Section(GoalText.reasonTitle(task)) {
                    Text(reason).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
