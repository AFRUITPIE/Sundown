import SwiftUI
import SundownKit
import TetherProtocol

/// One chat: its transcript, with the controls pinned to the bottom edge. Nothing else — the
/// window's title, subtitle and toolbar belong to the shell.
struct ThreadView: View {
    let thread: ThreadModel
    let connection: HostConnection
    /// The controls' height, which the transcript leaves as room after its end.
    @State private var barHeight: CGFloat = 0

    var body: some View {
        // The controls float over the transcript, so it passes under their glass, and the transcript
        // ends with room of their height: content, not a `safeAreaBar` or an inset. With their height
        // as the scroll view's bottom inset, the bottom anchor and a bottom-edge scroll position put
        // the end 55 pt apart, and they took turns on every streamed delta, so the end bounced
        // (macOS 27, 2026-10-09). Below the transcript in a stack, the glass had nothing under it.
        TranscriptView(thread: thread, connection: connection, bottomRoom: barHeight)
            .overlay(alignment: .bottom) {
                BottomBar(thread: thread, connection: connection)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { barHeight = $0 }
            }
            // Find in Chat's bar, above the transcript while it's open. An inset, not a `safeAreaBar`:
            // a top bar, even empty while Find is closed, took the toolbar's scroll edge effect, and
            // text scrolled up under the title and tabs unblurred.
            .safeAreaInset(edge: .top, spacing: 0) { FindBarHost(thread: thread) }
            .task(id: thread.id) { await connection.open(thread) }
            .modifier(OpensFileLinks(cwd: thread.cwd))
    }
}

#if DEBUG
#Preview("Idle chat") {
    NavigationStack {
        ThreadView(thread: .sampleIdleChat(), connection: .sample())
    }
    .frame(width: 900, height: 700)
}

/// View ▸ Tool Calls ▸ Every Call.
#Preview("Idle chat (every call)") {
    var appearance = Appearance()
    appearance.toolCalls = .everyCall
    return NavigationStack {
        ThreadView(thread: .sampleIdleChat(), connection: .sample())
    }
    .environment(\.appearance, appearance)
    .frame(width: 900, height: 700)
}

/// View ▸ Tool Calls, each way: runs summarized, each finished turn's work behind
/// one line, and every call on its own.
#Preview("Work (summarized)") { WorkChatPreview(toolCalls: .summarized) }
#Preview("Work (worked for)") { WorkChatPreview(toolCalls: .workedFor) }
#Preview("Work (every call)") { WorkChatPreview(toolCalls: .everyCall) }

private struct WorkChatPreview: View {
    let toolCalls: Appearance.ToolCallDisplay

    var body: some View {
        var appearance = Appearance()
        appearance.toolCalls = toolCalls
        return NavigationStack {
            ThreadView(thread: .sampleWorkChat(), connection: .sample())
        }
        .environment(\.appearance, appearance)
        .frame(width: 900, height: 800)
    }
}

#Preview("Running turn (code not wrapped)") {
    var appearance = Appearance()
    appearance.wrapCode = false
    return NavigationStack {
        ThreadView(thread: .sampleRunningTurn(), connection: .sample())
    }
    .environment(\.appearance, appearance)
    .frame(width: 900, height: 700)
}

#Preview("Idle chat (opens at the end)") {
    NavigationStack {
        ThreadView(thread: .sampleIdleChat(), connection: .sample())
    }
    .frame(width: 900, height: 360)
}

#Preview("Running turn") {
    NavigationStack {
        ThreadView(thread: .sampleRunningTurn(), connection: .sample())
    }
    .frame(width: 900, height: 700)
}

#Preview("Thinking (nothing to show yet)") {
    NavigationStack {
        ThreadView(thread: .sample(status: .running, items: [
            .sampleUserMessage("Why does opening a chat with the inspector open throw a constraints exception?", secondsAgo: 3),
        ]), connection: .sample())
    }
    .frame(width: 900, height: 400)
}

/// A background command settling between calls: one run of calls, the notice after it.
#Preview("Task settles mid-run") {
    let items: [Item] = [
        .sampleUserMessage("Run the tests in the background and keep going.", secondsAgo: 60),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("swift test")], status: .completed, secondsAgo: 55),
        .sampleToolCall(name: "Read", kind: .fileRead, input: ["file_path": .string("/tmp/App.swift")], status: .completed, secondsAgo: 50),
        .notice(.sample("Background command \"Run the package tests\" completed (exit code 0)", kind: "taskNotification", secondsAgo: 45)),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("git status")], status: .completed, secondsAgo: 40),
        .sampleAgentMessage("The tests pass and the tree is clean.", secondsAgo: 30),
    ]
    NavigationStack {
        ThreadView(thread: .sample(title: "Task settles mid-run", items: items, turns: [.sample()]), connection: .sample())
    }
    .frame(width: 900, height: 420)
}

/// Background agents, as Claude Code lays them out: one run of Agent calls, no line per report or
/// notice (Tasks has them), Claude's replies, and how many are still running under them.
#Preview("Background agents") {
    NavigationStack {
        ThreadView(thread: .sampleBackgroundAgents(), connection: .sample())
    }
    .frame(width: 900, height: 520)
}

#Preview("Background agents (while thinking)") {
    NavigationStack {
        ThreadView(thread: .sampleBackgroundAgents(status: .running, running: 5), connection: .sample())
    }
    .frame(width: 900, height: 420)
}

/// Claude using a skill, as a real session reads: the skill's instructions, which Claude Code puts
/// in the chat right after the call, are the call's (opened), not a message from Claude Code.
#Preview("Skill") {
    let items: [Item] = [
        .sampleUserMessage("Run the Sundown demo skill.", secondsAgo: 30),
        .toolCall(.sample(name: "Skill", kind: .skill, input: ["skill": "sundown-demo"], status: .completed,
                          outputText: "Launching skill: sundown-demo", secondsAgo: 28)),
        .sampleUserMessage("Base directory for this skill: /tmp/skilldemo/.claude/skills/sundown-demo\n\n# Sundown demo skill\n\nWhen this skill is used, reply with exactly one line.",
                           secondsAgo: 28, synthetic: true),
        .sampleAgentMessage("The Sundown demo skill ran.", secondsAgo: 26),
    ]
    NavigationStack {
        ThreadView(thread: .sample(title: "Skill", items: items, turns: [.sample()]), connection: .sample())
    }
    .frame(width: 900, height: 360)
}

/// The running tasks counted beside what's happening now: a run of calls with a command running,
/// then (its command done) the same run saying Thinking.
#Preview("Running tasks beside the current row", traits: .fixedLayout(width: 900, height: 620)) {
    @Previewable @State var commandDone = false
    let agents: [Item] = (1...3).map { n in
        .toolCall(.sample(id: "agent-\(n)", name: "Agent", kind: .subagent, input: ["description": .string("ls after \(n) s")],
                          status: .completed, secondsAgo: 20))
    }
    let command = Item.toolCall(.sample(id: "wc", name: "Bash", kind: .bash, input: ["command": "wc -l poem.md"],
                                        status: commandDone ? .completed : .running, secondsAgo: 2))
    let items: [Item] = [.sampleUserMessage("Delegate ls to 3 background agents, then count the poem's lines.", secondsAgo: 30)] + agents + [command]
    VStack(spacing: 0) {
        Toggle("Command done", isOn: $commandDone).padding(8)
        NavigationStack {
            ThreadView(thread: .sample(title: "Running tasks", status: .running, items: items,
                                       turns: [.sample(status: .inProgress)], backgroundTasks: 3),
                       connection: .sample())
        }
        .id(commandDone)
    }
}

#Preview("Pending permission") {
    NavigationStack {
        ThreadView(thread: .samplePendingPermission(), connection: .sample())
    }
    .frame(width: 900, height: 700)
}

/// The smallest detail column, in the smallest window: a prompt card must still leave the
/// transcript on screen.
#Preview("Pending permission (smallest window)") {
    NavigationStack {
        ThreadView(thread: .samplePendingPermission(), connection: .sample())
    }
    .frame(width: 520, height: 348)
}

#Preview("Pending plan (smallest window)") {
    NavigationStack {
        ThreadView(thread: .samplePendingPlan(), connection: .sample())
    }
    .frame(width: 520, height: 348)
}

// The transcript alone; the Tasks and Diff tabs and the toolbar's popovers have their own previews in `Panes/`.
#Preview("Tool call gallery") {
    NavigationStack {
        ThreadView(thread: .sampleToolCalls(), connection: .sample())
    }
    .frame(width: 1100, height: 760)
}

/// The one thing `readingColumn()` exists for: at every width the last message's left edge and the
/// composer's left edge are the same edge.
#Preview("Reading width alignment") {
    let connection = HostConnection.sample()
    VStack(spacing: 0) {
        ThreadView(thread: .sampleIdleChat(), connection: connection)
            .environment(\.readingWidth, TranscriptWidth.narrow.points)
        Divider()
        ThreadView(thread: .sampleIdleChat(), connection: connection)
            .environment(\.readingWidth, TranscriptWidth.medium.points)
        Divider()
        ThreadView(thread: .sampleIdleChat(), connection: connection)
            .environment(\.readingWidth, TranscriptWidth.wide.points)
    }
    .frame(width: 1240, height: 960)
}

#endif
