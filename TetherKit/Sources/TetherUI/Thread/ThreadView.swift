import SwiftUI
import TetherKit

/// One chat: its transcript, with the controls pinned to the bottom edge. Nothing else — the
/// window's title, subtitle, toolbar and inspector belong to the shell.
struct ThreadView: View {
    let thread: ThreadModel
    let connection: HostConnection

    var body: some View {
        TranscriptView(thread: thread, connection: connection)
            // Controls float over the transcript on glass; content scrolls underneath with the system edge effect.
            .safeAreaBar(edge: .bottom) {
                BottomBar(thread: thread, connection: connection)
            }
            // Find in Chat's bar, over the transcript while it's open.
            .safeAreaBar(edge: .top) { FindBarHost(thread: thread) }
            .task(id: thread.id) { await connection.open(thread) }
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

/// Taller than the window: it opens at its latest message. A shorter one sits at the top.
/// The other side of each choice in Settings ▸ Appearance.
#Preview("Idle chat (alternative appearance)") {
    var appearance = Appearance()
    appearance.promptStyle = .plain
    appearance.timestamps = .always
    appearance.toolIcons = true
    appearance.chevronSide = .leading
    appearance.statusSide = .leading
    appearance.groupToolCalls = false
    appearance.density = .spacious
    appearance.replyFont = .serif
    appearance.composerLayout = .inline
    appearance.replyCards = true
    return NavigationStack {
        ThreadView(thread: .sampleIdleChat(), connection: .sample())
    }
    .environment(\.appearance, appearance)
    .frame(width: 900, height: 700)
}

#Preview("Running turn (compact, minimal composer)") {
    var appearance = Appearance()
    appearance.density = .compact
    appearance.replyFont = .rounded
    appearance.composerLayout = .minimal
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
