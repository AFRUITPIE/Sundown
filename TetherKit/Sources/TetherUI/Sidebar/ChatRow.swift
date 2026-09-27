import SwiftUI
import TetherKit

/// One chat in the sidebar. Reads only what a row shows — never `items` or `rows` — so a
/// streaming turn cannot invalidate the sidebar.
struct ChatRow: View {
    let thread: ThreadModel
    /// The second line says what the section header doesn't.
    var grouping: SidebarGrouping = .date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ChatStatusGlyph(thread: thread)
                Text(thread.title).lineLimit(1)
            }
            if let secondary {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .badge(thread.pending.count)
    }

    /// The folder, where the section header doesn't already name it; otherwise when it was last used.
    private var secondary: String? {
        grouping == .date
            ? thread.cwd?.lastPathComponent
            : thread.summary.map { Format.relative(msSinceEpoch: $0.updatedAt) }
    }
}

/// Claude working in the chat, or waiting on you; nothing otherwise.
struct ChatStatusGlyph: View {
    let thread: ThreadModel

    var body: some View {
        if thread.isRunning {
            Image(systemName: thread.status == .requiresAction ? "exclamationmark.circle.fill" : "circle.dotted")
                .foregroundStyle(thread.status == .requiresAction ? .orange : Color.accentColor)
                .symbolEffect(.rotate, isActive: thread.status == .running)
        }
    }
}

/// One chat in the Activity sidebar, as Mail lists a message: the title (pinned or not) with its
/// folder on the same line, then the latest reply. The reply is `replyPreview`, which changes when
/// a reply completes, not per streamed token; a chat not opened this launch has none to show.
struct ActivityRow: View {
    let thread: ThreadModel
    var isPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ChatStatusGlyph(thread: thread)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                Text(thread.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Same priority as the title: a short folder name is shown whole, and a long one
                // shares the line rather than squeezing the title out.
                if let folder = thread.cwd?.lastPathComponent {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let preview = thread.replyPreview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .badge(thread.pending.count)
    }
}

#if DEBUG
#Preview("ActivityRow") {
    List {
        ActivityRow(thread: .sampleIdleChat(), isPinned: true)
        ActivityRow(thread: .sampleRunningTurn())
        ActivityRow(thread: .samplePendingPermission())
        ActivityRow(thread: .sampleListed(title: "A chat not opened this launch, so it has no reply to show",
                                          cwd: "/Users/hayden/Code/tether-server", secondsAgo: 3_600))
    }
    .listStyle(.sidebar)
    .frame(width: 280, height: 320)
}

#Preview("ChatRow (grouped by date)") {
    List {
        ChatRow(thread: .sampleIdleChat())
        ChatRow(thread: .sampleRunningTurn())
        ChatRow(thread: .samplePendingPermission())
        ChatRow(thread: .sampleErrorTurn())
        ChatRow(thread: .sampleListed(title: "A chat with a title long enough that it has to truncate somewhere",
                                      cwd: "/Users/hayden/Code/tether-server", secondsAgo: 3_600))
    }
    .listStyle(.sidebar)
    .frame(width: 280, height: 260)
}

#Preview("ChatRow (grouped by directory)") {
    List {
        ChatRow(thread: .sampleIdleChat(), grouping: .directory)
        ChatRow(thread: .sampleListed(title: "Bump the pinned server version", cwd: nil, secondsAgo: 90_000),
                grouping: .directory)
        ChatRow(thread: .sampleListed(title: "Trace the reconnect path", cwd: "/Users/hayden/Code/tether-server",
                                      secondsAgo: 40 * 86_400), grouping: .directory)
    }
    .listStyle(.sidebar)
    .frame(width: 280, height: 200)
}
#endif
