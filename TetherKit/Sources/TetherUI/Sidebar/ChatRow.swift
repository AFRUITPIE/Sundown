import SwiftUI
import TetherKit

/// One chat in the sidebar. Reads only what a row shows — never `items` or `rows` — so a
/// streaming turn cannot invalidate the sidebar.
struct ChatRow: View {
    let thread: ThreadModel
    /// The second line says what the section header doesn't.
    var grouping: SidebarGrouping = .date
    @Environment(\.appearance) private var appearance

    /// Waiting on you always shows; working, only with Settings ▸ Appearance ▸ Mark Chats Claude Is
    /// Working In.
    private var marked: Bool {
        thread.isRunning && (appearance.runningIndicator || thread.status == .requiresAction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if marked {
                    Image(systemName: thread.status == .requiresAction ? "exclamationmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(thread.status == .requiresAction ? .orange : Color.accentColor)
                        .symbolEffect(.rotate, isActive: thread.status == .running)
                }
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

    /// As Settings ▸ Appearance ▸ Chat Rows Show says; the folder only where the section header
    /// doesn't already name it.
    private var secondary: String? {
        let folder = grouping == .date ? thread.cwd?.lastPathComponent : nil
        let time = thread.summary.map { Format.relative(msSinceEpoch: $0.updatedAt) }
        let parts: [String?]
        switch appearance.rowDetail {
        case .titleOnly: parts = []
        case .folder: parts = grouping == .date ? [folder] : [time]
        case .folderAndTime: parts = [folder, time]
        }
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

#if DEBUG
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
