import SwiftUI
import SundownKit
import TetherProtocol

/// How a scheduled job reads: in its Tasks row, how often it fires or when next, and once it has
/// stopped, how many times it fired. Pure, so it's tested without a view.
enum ScheduleText {
    /// A row's line under the name, in place of a time.
    static func note(_ run: ScheduleRun) -> String {
        if run.state == .scheduled {
            if let next = run.nextFire { return "Next at \(time(next))" }
            if let every = run.humanSchedule { return every }
            if let cron = run.cron { return cron }
            return "Scheduled"
        }
        return fired(run.firings.count)
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
    static func repeats(_ run: ScheduleRun) -> String {
        if run.isWakeup { return "When Claude chooses" }
        if !run.recurring { return "Once" }
        return run.humanSchedule ?? run.cron ?? "Repeatedly"
    }

    /// What became of it, for the detail: the dot says how it stands, this says why.
    static func outcome(_ run: ScheduleRun) -> String? {
        switch run.state {
        case .scheduled: return nil
        case .done: return run.isWakeup ? "The loop ended" : "Fired its last time"
        case .deleted: return run.fromLoop ? "Loop stopped" : "Deleted"
        case .ended: return "Ended with its session"
        }
    }
}

/// How a goal reads: its checks so far.
enum GoalText {
    /// "Not checked yet", "1 check", "3 checks".
    static func checks(_ goal: GoalRun) -> String {
        let n = goal.checks
        return n == 0 ? "Not checked yet" : String(AttributedString(localized: "^[\(n) check](inflect: true)").characters)
    }

    /// The detail's heading over what the last check said.
    static func reasonTitle(_ goal: GoalRun) -> String {
        switch goal.state {
        case .met: "Why It’s Met"
        case .failed: "Why It Can’t Be Met"
        default: "Why It’s Not Met Yet"
        }
    }

    static func outcome(_ goal: GoalRun) -> String {
        switch goal.state {
        case .active: "Working toward it"
        case .met: "Met"
        case .failed: "Can’t be met"
        case .cleared: "Cleared"
        }
    }
}

/// A scheduled job on its own, in the Tasks tab's detail: what it fires with, how often, when it
/// fired. Nothing to stop it with: no request of the protocol deletes one (ask Claude to).
struct ScheduleReport: View {
    let run: ScheduleRun

    var body: some View {
        Form {
            Section("Prompt") {
                Text(run.title).textSelection(.enabled)
            }
            Section {
                LabeledContent("Repeats", value: ScheduleText.repeats(run))
                if run.state == .scheduled, let next = run.nextFire {
                    LabeledContent("Next", value: ScheduleText.time(next))
                }
                if let cron = run.cron, cron != run.humanSchedule {
                    LabeledContent("Cron") { Text(cron).monospaced().textSelection(.enabled) }
                }
                LabeledContent("Scheduled", value: ScheduleText.time(run.createdAt))
                LabeledContent("Fired", value: ScheduleText.fired(run.firings.count))
                if let last = run.firings.last {
                    LabeledContent("Last Fired", value: ScheduleText.time(last))
                }
                if let outcome = ScheduleText.outcome(run) {
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
    let goal: GoalRun

    var body: some View {
        Form {
            Section("Condition") {
                Text(goal.condition).textSelection(.enabled)
            }
            Section {
                LabeledContent("Status", value: GoalText.outcome(goal))
                LabeledContent("Checks", value: GoalText.checks(goal))
                LabeledContent("Set", value: ScheduleText.time(goal.setAt))
                if let ended = goal.endedAt {
                    LabeledContent(goal.state == .met ? "Met" : "Ended", value: ScheduleText.time(ended))
                }
            }
            if let reason = goal.lastReason {
                Section(GoalText.reasonTitle(goal)) {
                    Text(reason).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
