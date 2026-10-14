import SwiftUI
import SundownKit
import TetherProtocol

/// One chat: its transcript, with the controls pinned to the bottom edge. Nothing else — the
/// window's title, subtitle, toolbar and inspector belong to the shell.
struct ThreadView: View {
    let thread: ThreadModel
    let connection: HostConnection

    var body: some View {
        // The controls go below the transcript, not over it in a `safeAreaBar`: with their height as
        // the scroll view's bottom inset, the bottom anchor and a bottom-edge scroll position put the
        // end 55 pt apart, and they took turns on every streamed delta, so the end bounced
        // (macOS 27, 2026-10-09).
        VStack(spacing: 0) {
            TranscriptView(thread: thread, connection: connection)
            BottomBar(thread: thread, connection: connection)
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
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .sampleIdleChat(), connection: connection)
    }
    .frame(width: 900, height: 700)
}

/// View ▸ Tool Calls ▸ Every Call, and code that doesn't wrap.
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
#Preview("Work (summarized)") {
    NavigationStack {
        ThreadView(thread: .sampleWorkChat(), connection: .sample())
    }
    .frame(width: 900, height: 800)
}

#Preview("Work (worked for)") {
    var appearance = Appearance()
    appearance.toolCalls = .workedFor
    return NavigationStack {
        ThreadView(thread: .sampleWorkChat(), connection: .sample())
    }
    .environment(\.appearance, appearance)
    .frame(width: 900, height: 800)
}

#Preview("Work (every call)") {
    var appearance = Appearance()
    appearance.toolCalls = .everyCall
    return NavigationStack {
        ThreadView(thread: .sampleWorkChat(), connection: .sample())
    }
    .environment(\.appearance, appearance)
    .frame(width: 900, height: 800)
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
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .sampleRunningTurn(), connection: connection)
    }
    .frame(width: 900, height: 700)
}

#Preview("Thinking (nothing to show yet)") {
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .sample(status: .running, items: [
            .sampleUserMessage("Why does opening a chat with the inspector open throw a constraints exception?", secondsAgo: 3),
        ]), connection: connection)
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

/// A finished turn that narrated as it worked: its one-paragraph updates go into the runs, while a
/// note of two paragraphs and the answer stay.
#Preview("Work with updates (summarized)") {
    let items: [Item] = [
        .sampleUserMessage("Fix the failing release build.", secondsAgo: 120),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("xcodebuild -scheme Sundown")], status: .completed, secondsAgo: 115),
        .sampleAgentMessage("The build fails in the protocol package. Checking its pin:", secondsAgo: 110),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("cat Package.resolved")], status: .completed, secondsAgo: 105),
        .sampleAgentMessage("Pinned to 0.5.19. Bumping it:", secondsAgo: 100),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("swift package update")], status: .completed, secondsAgo: 95),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("xcodebuild -scheme Sundown")], status: .completed, secondsAgo: 90),
        .sampleAgentMessage("It builds now, but one test fails, and it's a real failure rather than a flaky one.\n\nThe fixture still sends the old handshake, so the client rejects it before any test step runs. Updating the fixture to send what 0.5.21 sends.", secondsAgo: 80),
        .sampleToolCall(name: "Bash", kind: .bash, input: ["command": .string("swift test")], status: .completed, secondsAgo: 70),
        .sampleAgentMessage("The release build passes again: the protocol package was pinned to 0.5.19, and the fixture now speaks 0.5.21's handshake.", secondsAgo: 60),
    ]
    NavigationStack {
        ThreadView(thread: .sample(title: "Work with updates", items: items, turns: [.sample()]), connection: .sample())
    }
    .frame(width: 900, height: 520)
}

#Preview("Pending permission") {
    let connection = HostConnection.sample()
    NavigationStack {
        ThreadView(thread: .samplePendingPermission(), connection: connection)
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

// The transcript alone; the inspector has its own previews in `Inspector/`.
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
