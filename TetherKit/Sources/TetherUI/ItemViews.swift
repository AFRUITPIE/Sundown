import SwiftUI
import TetherKit
import TetherProtocol

/// A transcript row's item as it is now. Reads the item's box, so a streamed delta redraws this row
/// alone: the row list it sits in holds the item's value from before the delta.
struct LiveItemView: View {
    let box: ItemBox
    let thread: ThreadModel

    var body: some View {
        ItemView(item: box.item, thread: thread)
    }
}

/// Renders one transcript item.
struct ItemView: View {
    let item: Item
    let thread: ThreadModel

    var body: some View {
        switch item {
        case .userMessage(let m):
            UserMessageView(message: m)
                .messageMenu(id: m.id, text: m.plainText, isMarkdown: false, sentAt: m.createdAt)
        case .agentMessage(let m):
            // Only the reply being streamed into fades its new text in; every other reply is settled.
            MarkdownView(text: m.text, streams: thread.streamingReplyID == m.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .messageMenu(id: m.id, text: m.text, isMarkdown: true, sentAt: m.createdAt)
        // Reasoning never renders; subagent items come through here too.
        case .reasoning: EmptyView()
        case .toolCall(let t): ToolCallView(call: t, thread: thread)
        case .compaction(let c):
            HStack {
                VStack { Divider() }
                Label("Conversation compacted" + (c.preTokens.map { " · \(Format.tokens($0)) tokens" } ?? ""), systemImage: "arrow.down.right.and.arrow.up.left")
                    .scaledFont(.caption).foregroundStyle(.secondary).fixedSize()
                VStack { Divider() }
            }
        // Quiet, like a failed call: said, selectable to copy, not alarming.
        case .error(let e):
            Label(e.message, systemImage: "exclamationmark.circle")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .notice(let n): NoticeView(notice: n)
        case .unknown(let v):
            DisclosureGroup("Unknown item: \(v["type"]?.stringValue ?? "?")") {
                Text(v.pretty).scaledFont(.caption, design: .monospaced).textSelection(.enabled)
            }
            .scaledFont(.caption)
        }
    }
}

/// What can be done with a message: copy it, branch the chat from it (Fork from Here), or, from a
/// prompt, put the files back as they were before it. In its context menu, and — since
/// right-clicking the words themselves gives the text's own menu, and a context menu shouldn't be
/// the only way to a command — in a small bar that appears on hover, with when it was sent.
/// VoiceOver gets the same as actions.
private struct MessageMenu: ViewModifier {
    let id: String
    /// The message as it arrived: plain for a prompt, Markdown for a reply.
    let text: String
    let isMarkdown: Bool
    /// Milliseconds since 1970.
    let sentAt: Double
    @Environment(\.forkChat) private var forkChat
    @Environment(\.restoreCode) private var restoreCode
    @State private var hovering = false

    /// A prompt's bubble sits at the trailing edge; a reply at the leading one.
    private var trailing: Bool { !isMarkdown }

    func body(content: Content) -> some View {
        content
            // The blank beside a short line is the message too, so right-clicking there works.
            .contentShape(.rect)
            .contextMenu {
                Button("Copy", action: copyText)
                if isMarkdown { Button("Copy as Markdown") { copy(text) } }
                Divider()
                Button("Fork from Here") { forkChat(id) }
                // Files go back to a prompt's checkpoint; a reply has none of its own.
                if !isMarkdown { Button("Restore Code to Here…") { restoreCode(id) } }
            }
            .overlay(alignment: trailing ? .topLeading : .topTrailing) {
                if hovering { bar.offset(y: -14) }
            }
            // After the overlay, so moving onto the bar doesn't hide it.
            .onHover { hovering = $0 }
            .accessibilityAction(named: "Copy", copyText)
            .accessibilityAction(named: "Fork from Here") { forkChat(id) }
            .accessibilityActions {
                if !isMarkdown { Button("Restore Code to Here…") { restoreCode(id) } }
            }
    }

    private var bar: some View {
        HStack(spacing: 2) {
            Text(Format.messageTime(msSinceEpoch: sentAt))
                .scaledFont(.caption, design: .default)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("message.time")
            Button("Copy", systemImage: "doc.on.doc", action: copyText)
                .help("Copy")
            Button("Fork from Here", systemImage: "arrow.triangle.branch") { forkChat(id) }
                .help("Fork from Here")
            if !isMarkdown {
                Button("Restore Code to Here…", systemImage: "clock.arrow.circlepath") { restoreCode(id) }
                    .help("Restore Code to Here")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .scaledFont(.callout, design: .default)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: .capsule)
    }

    // Converted when chosen, not per update: a streaming reply's body runs every frame.
    private func copyText() { copy(isMarkdown ? MarkdownView.plainText(text) : text) }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

extension View {
    func messageMenu(id: String, text: String, isMarkdown: Bool, sentAt: Double) -> some View {
        modifier(MessageMenu(id: id, text: text, isMarkdown: isMarkdown, sentAt: sentAt))
    }
}

extension Item.UserMessage {
    /// The message's text parts, as it would be pasted.
    var plainText: String {
        content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined(separator: "\n\n")
    }
}

/// Branches the window's chat after a message, keeping everything up to it, and opens the branch.
/// Compared by owner, like `InspectSubagentAction`, so a new closure doesn't redraw every message.
struct ForkChatAction: Equatable {
    private let owner: ObjectIdentifier?
    private let fork: @MainActor (String) -> Void

    init(owner: AnyObject?, fork: @escaping @MainActor (String) -> Void) {
        self.owner = owner.map(ObjectIdentifier.init)
        self.fork = fork
    }

    @MainActor func callAsFunction(_ messageID: String) { fork(messageID) }

    static func == (a: Self, b: Self) -> Bool { a.owner == b.owner }
}

extension EnvironmentValues {
    @Entry var forkChat = ForkChatAction(owner: nil) { _ in }
    /// Restore Code to Here…, for a prompt. The same shape as Fork from Here's.
    @Entry var restoreCode = ForkChatAction(owner: nil) { _ in }
    /// Shows a chat by id in the window, for a message that links to the chat it came from.
    @Entry var openChat = OpenChatAction(owner: nil, resolve: { _ in nil }, open: { _ in })
}

/// Shows a chat in the window by an id a message carries, when it's one of this host's listed chats.
/// Compared by owner, like `ForkChatAction`.
struct OpenChatAction: Equatable {
    private let owner: ObjectIdentifier?
    private let resolveID: @MainActor (String) -> String?
    private let open: @MainActor (String) -> Void

    init(owner: AnyObject?, resolve: @escaping @MainActor (String) -> String?, open: @escaping @MainActor (String) -> Void) {
        self.owner = owner.map(ObjectIdentifier.init)
        self.resolveID = resolve
        self.open = open
    }

    /// The listed chat `id` names, or nil when this host's list doesn't have it.
    @MainActor func resolve(_ id: String) -> String? { resolveID(id) }

    @MainActor func callAsFunction(_ id: String) {
        if let listed = resolveID(id) { open(listed) }
    }

    static func == (a: Self, b: Self) -> Bool { a.owner == b.owner }
}

struct UserMessageView: View {
    let message: Item.UserMessage
    @State private var images = MessageImageCache()

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            parts(alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.synthetic == true ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Who a message not typed here came from, in words rather than the SDK's kind.
    static func originLabel(_ origin: String?) -> String {
        switch origin {
        case "peer": "From Another Session"
        case "channel": "From a Channel"
        case "coordinator", "teamLead", "team-lead": "From the Team Lead"
        case nil: "From Claude Code"
        case let other?: "From \(other.humanized)"
        }
    }

    static func originSymbol(_ origin: String?) -> String {
        switch origin {
        case "peer": "bubble.left.and.bubble.right"
        case "channel": "dot.radiowaves.left.and.right"
        default: "gearshape"
        }
    }

    private func parts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if message.synthetic == true {
                HStack(spacing: 6) {
                    Label(message.originName.map { "From “\($0)”" } ?? Self.originLabel(message.origin),
                          systemImage: Self.originSymbol(message.origin))
                    if let session = message.originSession {
                        PeerSessionLink(sessionID: session)
                    }
                }
                .scaledFont(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let t):
                    Text(t.text)
                        .textSelection(.enabled)
                        .lineLimit(message.synthetic == true ? 6 : nil)
                case .image(let img):
                    if let ns = images.image(for: img.data) {
                        Image(nsImage: ns).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                case .fileRef(let f):
                    Label(f.path, systemImage: "doc").scaledFont(.callout)
                case .document(let d):
                    Label(d.name ?? "PDF Document", systemImage: "doc.richtext").scaledFont(.callout)
                case .unknown:
                    EmptyView()
                }
            }
            if message.queued == true {
                Text("Sent while running").scaledFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(message.synthetic == true ? .secondary : .primary)
        // A group VoiceOver names as it enters: whose message this is.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.synthetic == true ? Self.originLabel(message.origin) : "You")
    }
}

/// Opens the session a message came from. Dimmed, and saying why, when it isn't one of this host's
/// listed chats, rather than a link that does nothing.
private struct PeerSessionLink: View {
    let sessionID: String
    @Environment(\.openChat) private var openChat

    var body: some View {
        let listed = openChat.resolve(sessionID) != nil
        Button("Open Sender’s Chat") { openChat(sessionID) }
            .buttonStyle(.link)
            // The message around it is secondary; a link still reads as one, and dims when it can't go.
            .foregroundStyle(listed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .disabled(!listed)
            .help(listed ? "Show the chat this message came from" : "The chat this message came from isn’t in this host’s list")
    }
}

@MainActor
private final class MessageImageCache {
    private var values: [String: NSImage] = [:]

    func image(for base64: String) -> NSImage? {
        if let value = values[base64] { return value }
        guard let data = Data(base64Encoded: base64), let value = NSImage(data: data) else { return nil }
        values[base64] = value
        return value
    }
}

struct NoticeView: View {
    let notice: Item.Notice

    var body: some View {
        let symbol = switch notice.kind {
        case "interrupted": "stop.circle"
        case "localCommandOutput": "terminal"
        case "modelFallback": "arrow.triangle.swap"
        case "taskNotification": notice.level == .warning ? "exclamationmark.circle" : "checkmark.circle"
        default: "info.circle"
        }
        Label {
            Text(notice.text).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol)
        }
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("User message") {
    ScrollView {
        ItemView(item: .sampleUserMessage("Can you clean up the build directory before we cut a release?", secondsAgo: 30), thread: .sampleIdleChat())
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
    }
    .frame(width: 640, height: 200)
}

#Preview("User message (synthetic)") {
    ScrollView {
        ItemView(item: .sampleUserMessage("Compacted 3 earlier turns to stay under the context limit.", secondsAgo: 30, synthetic: true, origin: "compaction"), thread: .sampleIdleChat())
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
    }
    .frame(width: 640, height: 160)
}

/// A message from another session: its link opens the sender's chat when this host lists it, and
/// is dimmed, saying why, when it doesn't.
#Preview("User message (from another session)") {
    let listed = Item.userMessage(.init(id: "peer-1", createdAt: 0, content: [.text(.init(text: "The API tests pass on main now."))],
                                        synthetic: true, origin: "peer", originName: "CI babysitter", originSession: "listed"))
    let unlisted = Item.userMessage(.init(id: "peer-2", createdAt: 0, content: [.text(.init(text: "Deploy finished."))],
                                          synthetic: true, origin: "peer", originSession: "elsewhere"))
    return VStack(spacing: 16) {
        ItemView(item: listed, thread: .sampleIdleChat())
        ItemView(item: unlisted, thread: .sampleIdleChat())
    }
    .environment(\.openChat, OpenChatAction(owner: nil, resolve: { $0 == "listed" ? $0 : nil }, open: { _ in }))
    .padding(28)
    .frame(width: 640)
}

#Preview("Agent message") {
    ScrollView {
        ItemView(item: .sampleAgentMessage("Sure — I ran `rm -rf .build` and confirmed the workspace still builds cleanly.", secondsAgo: 10), thread: .sampleIdleChat())
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
    }
    .frame(width: 640, height: 160)
}

#Preview("Notice") {
    ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            ItemView(item: .sampleNotice("Switched to Claude Sonnet 5 after a rate limit on Opus.", kind: "modelFallback", level: .warning, secondsAgo: 5), thread: .sampleIdleChat())
            ItemView(item: .sampleNotice("Interrupted by user.", kind: "interrupted", level: .info, secondsAgo: 5), thread: .sampleIdleChat())
            ItemView(item: .sampleNotice("$ swift build --target TetherKit", kind: "localCommandOutput", secondsAgo: 5), thread: .sampleIdleChat())
            ItemView(item: .sampleNotice("Background command \"Sleep then echo\" completed (exit code 0)", kind: "taskNotification", secondsAgo: 5), thread: .sampleIdleChat())
            ItemView(item: .sampleNotice("Background command \"Run the migration\" failed with exit code 1", kind: "taskNotification", level: .warning, secondsAgo: 5), thread: .sampleIdleChat())
        }
        .padding(28)
    }
    .frame(width: 640, height: 280)
}

#Preview("Error item") {
    ScrollView {
        ItemView(item: .error(.init(id: "err-1", createdAt: 0, message: "The model reported an internal error and the turn could not continue.")), thread: .sampleIdleChat())
            .padding(28)
    }
    .frame(width: 640, height: 160)
}

#Preview("Full transcript") {
    let thread = ThreadModel.sampleIdleChat()
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(thread.topLevelItems, id: \.id) { item in
                ItemView(item: item, thread: thread)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: 920)
    }
    .frame(width: 760, height: 560)
}

#endif
