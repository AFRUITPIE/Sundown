import SwiftUI
import TetherKit

/// One chat: its transcript, with the controls pinned to the bottom edge. Nothing else — the
/// window's title, subtitle, toolbar and inspector belong to the shell.
struct ThreadView: View {
    let thread: ThreadModel
    let connection: HostConnection

    var body: some View {
        TranscriptView(thread: thread, connection: connection)
            // Controls float over the transcript on glass; content scrolls underneath with a soft edge.
            .safeAreaBar(edge: .bottom) {
                BottomBar(thread: thread, connection: connection)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // The same soft edge under the toolbar.
            .scrollEdgeEffectStyle(.soft, for: .top)
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
