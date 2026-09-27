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
                .messageMenu(id: m.id, text: m.plainText, isMarkdown: false)
        case .agentMessage(let m):
            MarkdownView(text: m.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .messageMenu(id: m.id, text: m.text, isMarkdown: true)
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
        case .error(let e):
            Label(e.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .notice(let n): NoticeView(notice: n)
        case .unknown(let v):
            DisclosureGroup("Unknown item: \(v["type"]?.stringValue ?? "?")") {
                Text(v.pretty).scaledFont(.caption, design: .monospaced).textSelection(.enabled)
            }
            .scaledFont(.caption)
        }
    }
}

/// What can be done with a message: copy it, or branch the chat from it (Fork from Here). In its
/// context menu, and — since right-clicking the words themselves gives the text's own menu, and a
/// context menu shouldn't be the only way to a command — in a small bar that appears on hover.
/// VoiceOver gets the same as actions.
private struct MessageMenu: ViewModifier {
    let id: String
    /// The message as it arrived: plain for a prompt, Markdown for a reply.
    let text: String
    let isMarkdown: Bool
    @Environment(\.forkChat) private var forkChat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            // The blank beside a short line is the message too, so right-clicking there works.
            .contentShape(.rect)
            .contextMenu {
                Button("Copy", action: copyText)
                if isMarkdown { Button("Copy as Markdown") { copy(text) } }
                Divider()
                Button("Fork from Here") { forkChat(id) }
            }
            .overlay(alignment: .topTrailing) {
                if hovering { actions.offset(y: -14) }
            }
            // After the overlay, so moving onto the bar doesn't hide it.
            .onHover { hovering = $0 }
            .accessibilityAction(named: "Copy", copyText)
            .accessibilityAction(named: "Fork from Here") { forkChat(id) }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button("Copy", systemImage: "doc.on.doc", action: copyText)
                .help(isMarkdown ? "Copy this reply as text" : "Copy this message")
            Button("Fork from Here", systemImage: "arrow.triangle.branch") { forkChat(id) }
                .help("Start a new chat with the conversation up to here")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .scaledFont(.callout)
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
    func messageMenu(id: String, text: String, isMarkdown: Bool) -> some View {
        modifier(MessageMenu(id: id, text: text, isMarkdown: isMarkdown))
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
}

struct UserMessageView: View {
    let message: Item.UserMessage
    @State private var images = MessageImageCache()

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if message.synthetic == true {
                    Label(message.origin ?? "system", systemImage: "gearshape")
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
                    case .unknown:
                        EmptyView()
                    }
                }
                if message.queued == true {
                    Text("Sent while running").scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.synthetic == true ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(message.synthetic == true ? .secondary : .primary)
        }
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
        .foregroundStyle(notice.level == .warning ? AnyShapeStyle(.orange) : notice.level == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
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
