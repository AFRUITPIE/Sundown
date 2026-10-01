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
            // The dot sits on the title's line, in a gutter the line below shares, so titles align.
            HStack(spacing: ChatStatusDot.spacing) {
                ChatStatusDot(state: .init(thread))
                // Claude names a chat a moment after its first turn: the opening prompt turns into it.
                ReplacingText(thread.title).lineLimit(1)
            }
            secondary
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, ChatStatusDot.gutter)
        }
        .badge(thread.pending.count)
    }

    /// The folder, where the section header doesn't already name it; otherwise when it was last
    /// used, which keeps itself current ("5 minutes ago") as time passes.
    @ViewBuilder private var secondary: some View {
        if grouping == .date {
            if let folder = thread.cwd?.lastPathComponent { Text(folder) }
        } else if let updated = thread.summary?.updatedAt {
            Text(.currentDate, format: .reference(to: Date(timeIntervalSince1970: updated / 1000)))
        }
    }
}

/// Where a chat stands, as the sidebar's dot says it, Mail-style: Claude working (blue, pulsing),
/// waiting on you (orange), a reply you haven't seen (green), a turn that failed (red) or that was
/// stopped (a ring); nothing once you've seen how it ended.
enum ChatState: Hashable {
    case working, needsYou, newReply, failed, stopped, idle

    @MainActor init(_ thread: ThreadModel) {
        if thread.status == .requiresAction { self = .needsYou }
        else if thread.isRunning || thread.status == .starting { self = .working }
        else if thread.hasUnseenReply { self = .newReply }
        else if thread.lastTurnStatus == .failed || thread.status == .error { self = .failed }
        else if thread.lastTurnStatus == .interrupted { self = .stopped }
        else { self = .idle }
    }

    /// Said, not only drawn: a color is all a row has for it.
    var label: String? {
        switch self {
        case .working: "Working"
        case .needsYou: "Needs You"
        case .newReply: "New Reply"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .idle: nil
        }
    }
}

/// The sidebar row's status dot. Working pulses with the symbol's own effect (opacity only, so the
/// dot never moves), except under Reduce Motion or while the Mac saves energy.
struct ChatStatusDot: View {
    let state: ChatState
    static let size: CGFloat = 8
    static let spacing: CGFloat = 6
    /// The dot and its spacing: how far the row's other lines are indented to line up with the title.
    static let gutter = size + spacing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reducesEffects) private var reducesEffects

    var body: some View {
        ZStack {
            switch state {
            case .working:
                Image(systemName: "circle.fill")
                    .resizable()
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && !reducesEffects)
            case .needsYou: Circle().fill(.orange)
            case .newReply: Circle().fill(.green)
            case .failed: Circle().fill(.red)
            case .stopped: Circle().fill(.white).overlay(Circle().strokeBorder(.secondary, lineWidth: 1.5))
            case .idle: Color.clear
            }
        }
        .frame(width: Self.size, height: Self.size)
        .animation(reduceMotion ? nil : .default, value: state)
        .accessibilityHidden(state.label == nil)
        .accessibilityLabel(state.label ?? "")
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
            // The folder on the title's baseline; the dot centred on the title.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                HStack(spacing: 4) {
                    ChatStatusDot(state: .init(thread))
                        .padding(.trailing, ChatStatusDot.spacing - 4)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    ReplacingText(thread.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
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
                    .padding(.leading, ChatStatusDot.gutter)
            }
        }
        .badge(thread.pending.count)
    }
}

#if DEBUG
#Preview("Status dots") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach([ChatState.working, .needsYou, .newReply, .failed, .stopped, .idle], id: \.self) { state in
            HStack(spacing: ChatStatusDot.spacing) {
                ChatStatusDot(state: state)
                Text(state.label ?? "Idle")
            }
        }
    }
    .padding()
}

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
