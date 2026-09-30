import ImageIO
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
    @Environment(\.messageSendOwner) private var sendOwner

    var body: some View {
        switch item {
        case .userMessage(let m):
            let isLocalSend = thread.isRecentLocalSend(m.id, owner: sendOwner)
            UserMessageView(message: m, justSent: isLocalSend,
                            canAnimate: thread.canAnimateSend(m.id, owner: sendOwner),
                            claimSendAnimation: { thread.consumeSendAnimation(m.id, owner: sendOwner) })
                .messageMenu(id: m.id, text: m.plainText, isMarkdown: false, sentAt: m.createdAt,
                             arrivalID: isLocalSend ? m.id : nil,
                             animateArrival: thread.canAnimateSend(m.id, owner: sendOwner))
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
                Label(c.preTokens.map { "Conversation compacted · \(Format.tokens($0)) tokens" } ?? "Conversation compacted",
                      systemImage: "arrow.down.right.and.arrow.up.left")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    // The rules on either side give way first.
                    .layoutPriority(1)
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
/// prompt, put the files back as they were before it. Regular controls live below the message,
/// rather than floating over selectable text. Context menus and VoiceOver offer the same actions.
private struct MessageMenu: ViewModifier {
    let id: String
    /// The message as it arrived: plain for a prompt, Markdown for a reply.
    let text: String
    let isMarkdown: Bool
    /// Milliseconds since 1970.
    let sentAt: Double
    let arrivalID: String?
    let animateArrival: Bool
    @State private var arrivalPrepared = false
    @Environment(\.forkChat) private var forkChat
    @Environment(\.restoreCode) private var restoreCode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reducesEffects) private var reducesEffects
    @Environment(\.messageSendGeometry) private var sendGeometry

    private var hidesActions: Bool {
        !reduceMotion && !reducesEffects &&
        (sendGeometry?.activeMessageID == id || (animateArrival && !arrivalPrepared))
    }

    /// A prompt's bubble sits at the trailing edge; a reply at the leading one.
    private var trailing: Bool { !isMarkdown }

    func body(content: Content) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 8) {
            content
                // The blank beside a short line is the message too, so right-clicking there works.
                .contentShape(.rect)
                .contextMenu { actions }
            bar
                .opacity(hidesActions ? 0 : 1)
                .allowsHitTesting(!hidesActions)
                .accessibilityHidden(hidesActions)
                .animation(.easeOut(duration: 0.12), value: hidesActions)
        }
            // A reply is one element, as a prompt's bubble is, so its actions are the reply's and not
            // each paragraph's; and says when it was sent, as the inline footer does visually.
            .modifier(ReplyElement(isReply: isMarkdown))
            // A date and a style, formatted only when VoiceOver reads it, not per streamed delta.
            .accessibilityCustomContent(Text("Sent"), Text(Date(timeIntervalSince1970: sentAt / 1000),
                                                            format: .dateTime.month(.abbreviated).day().hour().minute()))
            .accessibilityAction(named: "Copy", copyText)
            .accessibilityAction(named: "Fork from Here") { forkChat(id) }
            .accessibilityActions {
                if !isMarkdown { Button("Restore Code to Here…") { restoreCode(id) } }
            }
            .task(id: arrivalID) {
                arrivalPrepared = true
            }
    }

    @ViewBuilder private var actions: some View {
        Button("Copy", action: copyText)
        if isMarkdown { Button("Copy as Markdown") { Clipboard.copy(text) } }
        Divider()
        Button("Fork from Here", systemImage: "arrow.triangle.branch") { forkChat(id) }
        if !isMarkdown {
            Button("Restore Code to Here…", systemImage: "clock.arrow.circlepath") { restoreCode(id) }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Text(Format.messageTime(msSinceEpoch: sentAt))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("message.time")
            CopyButton(action: copyText, spacious: true)
                .accessibilityIdentifier("message.copy.\(id)")
            Menu {
                if isMarkdown { Button("Copy as Markdown") { Clipboard.copy(text) } }
                Button("Fork from Here", systemImage: "arrow.triangle.branch") { forkChat(id) }
                if !isMarkdown {
                    Button("Restore Code to Here…", systemImage: "clock.arrow.circlepath") { restoreCode(id) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .padding(4)
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .help("More Message Actions")
            .accessibilityLabel("More Message Actions")
            .accessibilityIdentifier("message.more.\(id)")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .scaledFont(.callout)
    }

    // Converted when chosen, not per update: a streaming reply's body runs every frame.
    private func copyText() { Clipboard.copy(isMarkdown ? MarkdownView.plainText(text) : text) }
}

/// Copy, which turns into a checkmark for a moment once it has copied. As wide as the wider of the
/// two, so turning into the checkmark doesn't resize the bar it's in and move the buttons beside it.
struct CopyButton: View {
    let action: () -> Void
    var spacious = false
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
        } label: {
            ReservedWidthLabel(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc",
                               widestOf: ["Copy", "Copied"], symbols: ["doc.on.doc", "checkmark"])
                .padding(.vertical, spacious ? 4 : 0)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
        .help("Copy")
    }
}

extension View {
    func messageMenu(id: String, text: String, isMarkdown: Bool, sentAt: Double,
                     arrivalID: String? = nil, animateArrival: Bool = false) -> some View {
        modifier(MessageMenu(id: id, text: text, isMarkdown: isMarkdown, sentAt: sentAt,
                             arrivalID: arrivalID, animateArrival: animateArrival))
    }
}

/// A reply as one VoiceOver element holding its paragraphs, named for who wrote it. A prompt's
/// bubble already is one.
private struct ReplyElement: ViewModifier {
    let isReply: Bool

    func body(content: Content) -> some View {
        if isReply {
            content.accessibilityElement(children: .contain).accessibilityLabel("Claude")
        } else {
            content
        }
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
    let claimSendAnimation: () -> Bool
    let justSent: Bool
    let canAnimate: Bool
    @State private var arrived: Bool
    @State private var sending = false
    @State private var prepared = false
    @State private var launchFrame: CGRect?
    @State private var launchPreparation: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reducesEffects) private var reducesEffects
    @Environment(\.messageSendGeometry) private var sendGeometry
    @Environment(\.colorSchemeContrast) private var contrast

    init(message: Item.UserMessage, justSent: Bool = false, canAnimate: Bool = true,
         claimSendAnimation: @escaping () -> Bool = { true }) {
        self.message = message
        self.claimSendAnimation = claimSendAnimation
        self.justSent = justSent
        self.canAnimate = canAnimate
        _arrived = State(initialValue: true)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            surface
                .modifier(SentMessagePosition(arrived: arrived || reduceMotion || reducesEffects,
                                              origin: sending ? launchFrame : nil))
                .opacity(justSent && canAnimate && !prepared && !reduceMotion && !reducesEffects ? 0 : 1)
                // The transient subtree settles before selection starts, so a mid-flight drag
                // cannot begin a selection that the glass-to-fill handoff would discard.
                .allowsHitTesting(!sending)
        }
        .task(id: justSent) {
            guard justSent else { prepared = true; arrived = true; sending = false; return }
            guard claimSendAnimation(), !reduceMotion, !reducesEffects else {
                prepared = true
                arrived = true
                return
            }
            sendGeometry?.activeMessageID = message.id
            launchPreparation = sendGeometry?.preparationID
            launchFrame = sendGeometry?.submittedFrame ?? sendGeometry?.composerFrame
            sendGeometry?.submittedFrame = nil
            sending = true
            arrived = false
            prepared = true
            defer {
                arrived = true
                sending = false
                sendGeometry?.finishSend(message.id, preparation: launchPreparation)
            }
            // Give the visual effect its initial render at the composer before lifting into the row.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { arrived = true; sending = false; return }
            // A damped spring gives the reference's acceleration, small overshoot and soft return.
            // Completion follows the actual spring tail, rather than replacing glass on a timer.
            await withCheckedContinuation { continuation in
                withAnimation(MessageSendGeometry.spring, completionCriteria: .removed) {
                    arrived = true
                    sendGeometry?.departingMessageID = message.id
                } completion: {
                    continuation.resume()
                }
            }
            guard !Task.isCancelled else { return }
        }
        .onDisappear {
            arrived = true
            sending = false
            sendGeometry?.finishSend(message.id, preparation: launchPreparation)
        }
    }

    /// Only the active handoff's background needs a glass renderer. Its text stays outside the
    /// capture so an independently morphing surface cannot composite over the message.
    private var surface: some View { bubble }

    private var bubble: some View {
        parts(alignment: .trailing)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .scaleEffect(sending && !arrived ? 0.92 : 1, anchor: .bottomTrailing)
            .background(alignment: .bottomTrailing) {
                if sending {
                    SendingMessageSurface(arrived: arrived, origin: launchFrame, blue: bubbleBlue)
                        .transition(.identity)
                } else {
                    RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
                        .fill(message.synthetic == true ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(bubbleBlue))
                }
            }
    }

    /// System blue keeps the Messages-inspired identity across appearances. A modest dark mix
    /// gives small white text enough separation; Increased Contrast strengthens it further.
    private var bubbleBlue: Color {
        .blue.mix(with: .black, by: contrast == .increased ? 0.30 : 0.16)
    }

    /// Whether a part has something to show, so an unknown one takes no space.
    static func draws(_ part: UserInput) -> Bool {
        if case .unknown = part { return false }
        return true
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
            ForEach(Array(message.content.enumerated()).filter { Self.draws($0.element) }, id: \.offset) { index, part in
                // One view a part, even one that shows nothing, so SwiftUI can count them.
                VStack(alignment: .trailing, spacing: 0) {
                    switch part {
                    case .text(let t):
                        Text(t.text)
                            .textSelection(.enabled)
                            .lineLimit(message.synthetic == true ? 6 : nil)
                    case .image(let img):
                        MessageImage(key: "\(message.id)#\(index)", base64: img.data)
                    case .fileRef(let f):
                        Label(f.path, systemImage: "doc").scaledFont(.callout)
                    case .document(let d):
                        Label(d.name ?? "PDF Document", systemImage: "doc.richtext").scaledFont(.callout)
                    case .unknown:
                        EmptyView()
                    }
                }
            }
            if message.queued == true {
                Text("Sent while running").scaledFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(message.synthetic == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
        // A group VoiceOver names as it enters: whose message this is.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.synthetic == true ? Self.originLabel(message.origin) : "You")
    }
}

/// Transform the complete rendered surface, after its glass effect. Visual geometry leaves the
/// final row's layout untouched and avoids reshaping or rewrapping selectable text in flight.
private struct SentMessagePosition: ViewModifier {
    let arrived: Bool
    let origin: CGRect?

    @ViewBuilder func body(content: Content) -> some View {
        if let origin {
            content.visualEffect { effect, geometry in
                let target = geometry.frame(in: .named(MessageSendGeometry.space))
                return effect
                    .offset(x: arrived ? 0 : origin.maxX - target.maxX,
                            y: arrived ? 0 : origin.maxY - target.maxY)
            }
        } else {
            content
        }
    }
}

/// Only the background's inexpensive shape changes size. Its rounded corners stay circular,
/// while the independently drawn text keeps its final measurement and line breaks.
private struct SendingMessageSurface: View {
    let arrived: Bool
    let origin: CGRect?
    let blue: Color
    @State private var size: CGSize = .zero

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay(alignment: .bottomTrailing) {
                GlassEffectContainer {
                    RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
                        .fill(blue)
                        .frame(width: arrived ? size.width : origin?.width ?? size.width,
                               height: arrived ? size.height : origin?.height ?? size.height)
                        .glassEffect(.regular.tint(blue), in: .rect(cornerRadius: Layout.cardCornerRadius))
                        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: arrived)
                }
            }
    }
}

/// One stable coordinate space per detail column, preserved when New Chat becomes a chat.
/// Only a sending bubble reads the frame. No scroll-frame state reaches the transcript's rows.
@MainActor @Observable
final class MessageSendGeometry {
    nonisolated static let space = "message.send"
    static let spring = Animation.spring(response: 0.52, dampingFraction: 0.74)
    var composerFrame: CGRect?
    @ObservationIgnored var submittedFrame: CGRect?
    var activeMessageID: String?
    var preparationID: UUID?
    var departingMessageID: String?

    func prepareSend() -> UUID {
        let token = UUID()
        submittedFrame = composerFrame
        departingMessageID = nil
        preparationID = token
        return token
    }

    func cancelPreparation(_ token: UUID?) {
        guard token == preparationID else { return }
        preparationID = nil
    }

    func finishSend(_ id: String, preparation token: UUID?) {
        guard activeMessageID == id else { return }
        activeMessageID = nil
        if preparationID == token { preparationID = nil }
        if departingMessageID == id { departingMessageID = nil }
    }
}

extension EnvironmentValues {
    @Entry var messageSendGeometry: MessageSendGeometry? = nil
    @Entry var messageSendOwner: UUID? = nil
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

/// An image in a prompt. Decoded and scaled down off the main actor the first time it's shown, and
/// kept app-wide by its message and place, so a row made again draws it at once; a quiet box holds
/// its place until then. Decoding every image whole on the main thread, and keying a row's cache by
/// its megabytes of base64, took a chat with screenshots a moment to open.
private struct MessageImage: View {
    let key: String
    let base64: String
    @State private var image: MessageImages.Decoded?
    @State private var unreadable = false

    var body: some View {
        if let image = image ?? MessageImages.cached(key) {
            Image(image.cgImage, scale: image.scale, label: Text("Attached Image"))
                .resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIgnoresInvertColors()
        } else if !unreadable {
            RoundedRectangle(cornerRadius: 6)
                .fill(.fill.tertiary)
                .frame(width: 120, height: 90)
                .accessibilityLabel("Attached Image")
                .task(id: key) {
                    image = await MessageImages.load(key, base64: base64)
                    unreadable = image == nil && !Task.isCancelled
                }
        }
    }
}

/// Prompts' images, scaled to the most a prompt shows, by message id and part.
@MainActor
enum MessageImages {
    /// An image as drawn: its pixels, and how many of them make a point.
    final class Decoded: Sendable {
        let cgImage: CGImage
        let scale: CGFloat

        init(_ cgImage: CGImage, size: CGSize) {
            self.cgImage = cgImage
            scale = CGFloat(cgImage.width) / max(size.width, 1)
        }
    }

    private static let cache: NSCache<NSString, Decoded> = {
        let cache = NSCache<NSString, Decoded>()
        cache.totalCostLimit = 64 << 20 // decoded bytes
        return cache
    }()

    static func cached(_ key: String) -> Decoded? { cache.object(forKey: key as NSString) }

    static func load(_ key: String, base64: String) async -> Decoded? {
        if let image = cached(key) { return image }
        guard let decoded = await decode(base64) else { return nil }
        let image = Decoded(decoded.image, size: decoded.size)
        cache.setObject(image, forKey: key as NSString, cost: decoded.image.bytesPerRow * decoded.image.height)
        return image
    }

    /// At most 480 pixels on the long edge, 240 points at 2x, and upright. Its size in points is the
    /// whole image's (its pixels at its DPI), so a prompt lays out as a full-size image would.
    @concurrent
    nonisolated static func decode(_ base64: String) async -> (image: CGImage, size: CGSize)? {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              image.width > 0, image.height > 0 else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let whole = Double(max(width, height)), scaled = Double(max(image.width, image.height))
        return (image, CGSize(width: Double(image.width) * whole / scaled * 72 / dpi,
                              height: Double(image.height) * whole / scaled * 72 / dpi))
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

#Preview("Blue prompts, dark") {
    ItemView(item: .sampleUserMessage("A clearer blue bubble, with white text and a quick glass handoff.", secondsAgo: 30),
             thread: .sampleIdleChat())
        .padding(28).frame(width: 640)
        .preferredColorScheme(.dark)
}

#Preview("Blue prompts, light") {
    ItemView(item: .sampleUserMessage("A clearer blue bubble, with white text and a quick glass handoff.", secondsAgo: 30),
             thread: .sampleIdleChat())
        .padding(28).frame(width: 640)
        .preferredColorScheme(.light)
}

#Preview("Message controls") {
    ScrollView {
        VStack(spacing: 24) {
            ItemView(item: .sampleUserMessage("Keep the glass editing surface, with Send beside it.", secondsAgo: 30),
                     thread: .sampleIdleChat())
            ItemView(item: .agentMessage(.init(id: "reply-controls", createdAt: 0,
                                              text: "The controls now live below each message. **Copy** is one click; Fork and Restore are in **More**.")),
                     thread: .sampleIdleChat())
        }
        .padding(28)
    }
    .frame(width: 640, height: 340)
}

#Preview("Sending handoff") {
    MessageSendPreview()
        .frame(width: 640, height: 360)
}

private struct MessageSendPreview: View {
    @State private var geometry = MessageSendGeometry()
    @State private var sends = 0
    @State private var draft = "Make the interface feel at home on macOS."

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                if sends > 0 {
                    UserMessageView(message: .init(id: "preview-send", createdAt: 0,
                                                   content: [.text(.init(text: draft))]), justSent: true)
                        .id(sends)
                        .padding(24)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Layout.cardCornerRadius))
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(MessageSendGeometry.space))
                    } action: { geometry.composerFrame = $0 }
                Button("Send", systemImage: "arrow.up") { sends += 1 }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(24)
        }
        .coordinateSpace(name: MessageSendGeometry.space)
        .environment(\.messageSendGeometry, geometry)
    }
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

/// A prompt with a screenshot, decoded off the main actor the first time it's shown.
#Preview("User message (image)") {
    ScrollView {
        ItemView(item: .userMessage(.init(id: "image-1", createdAt: 0, content: [
            .text(.init(text: "The sidebar clips here — can you take a look?")),
            .image(.init(mediaType: .imagePng, data: previewScreenshot())),
        ])), thread: .sampleIdleChat())
        .padding(28)
    }
    .frame(width: 640, height: 320)
}

/// A 1280×800 "screenshot": a window's sidebar and content, as a PNG in base64.
private func previewScreenshot() -> String {
    let width = 1280, height = 800
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: height))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.47, blue: 0.96, alpha: 1))
    context.fill(CGRect(x: 24, y: height - 140, width: 272, height: 44))
    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return "" }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return (data as Data).base64EncodedString()
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
