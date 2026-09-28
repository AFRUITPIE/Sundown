import ImageIO
import SwiftUI
import TetherKit
import TetherProtocol
import UniformTypeIdentifiers

/// Prompt field: native multi-line TextField (Return or ⌘Return sends, per Settings) with native
/// input suggestions for `/` commands and `@` file mentions, image attachments, and send-while-running.
///
/// The only thread properties it reads are `promptSuggestion` and `isRunning`, both of which change
/// at turn boundaries rather than per streamed delta, so a running turn doesn't re-render the field.
/// It also reads the connection's state: while the host isn't connected, `ConnectionStatusCard`
/// takes the field's place.
struct Composer: View {
    let connection: HostConnection
    let cwd: String?
    var thread: ThreadModel?
    /// Where the unsent text is kept between visits: the chat's id, or New Chat's per host.
    var draftKey: String?
    var placeholder = "Ask Claude…"
    /// A server request is waiting: the draft stays, but it has to be answered before sending.
    var awaitingAnswer = false
    var onStop: (() -> Void)?
    let submit: ([UserInput]) async -> Void
    /// Told when the message field gains or loses focus.
    var onFocusChange: ((Bool) -> Void)?
    /// Takes a directory dropped on the field, as New Chat's directory, instead of mentioning it.
    var takesDirectory: ((String) -> Void)?

    @Environment(\.composerDraft) private var composerDraft
    @Environment(\.composerDrafts) private var drafts
    @Environment(\.appearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var images: [Attachment] = []
    @State private var commands: [SlashCommand] = []
    /// Whether `commands` is this folder's or chat's list, rather than nothing asked for yet.
    @State private var commandsLoaded = false
    /// Someone looked for a command (a typed "/", the + menu): the list is asked for then, not
    /// when the chat is shown, since the host starts a Claude Code process in the folder to answer.
    @State private var commandsWanted = false
    @State private var fileMatches: [String] = []
    @State private var suggestions: [Suggestion] = []
    @State private var choosingFiles = false
    /// Counts sends, for Send's spring.
    @State private var sends = 0
    /// The last text put here from outside the field (`ComposerDrafts.delivery`), so each is applied once.
    @State private var appliedDelivery: UUID?
    /// The text Esc closed the suggestion list on: it stays closed until the text changes.
    @State private var suggestionsClosedFor: String?
    @FocusState private var focused: Bool
    @Namespace private var glass
    /// Something is being dragged over the field.
    @State private var dropTargeted = false
    /// Files being read and images prepared, off the main actor: the message waits for them.
    @State private var attaching = 0

    private enum GlassID: Hashable { case field }

    /// Something going with the message besides its text. Made off the main actor, ready to send.
    struct Attachment: Identifiable, Sendable {
        let id = UUID()
        let kind: Kind
        /// An image's picture for its chip, made when it was attached: decoding the image in the
        /// chip's body did it again on every keystroke.
        var thumbnail: CGImage?

        /// What it's called, to VoiceOver and in its Remove button.
        var title: String {
            switch kind {
            case .image: "Image"
            case .pdf(_, let name), .text(_, let name): name
            }
        }

        enum Kind: Sendable {
            /// An image as it's sent: base64, and PNG, JPEG, GIF or WebP.
            case image(base64: String, mediaType: UserInput.Image.MediaType)
            /// A PDF, base64, sent as a document Claude reads.
            case pdf(base64: String, name: String)
            /// A text file's contents, for a host that can't read the file where it is.
            case text(String, name: String)
        }

        var input: UserInput {
            switch kind {
            case .image(let base64, let mediaType):
                .image(.init(mediaType: mediaType, data: base64))
            case .pdf(let base64, let name):
                .document(.init(mediaType: .applicationPdf, data: base64, name: name))
            case .text(let content, let name):
                .text(.init(text: "Contents of \(name):\n```\n\(content)\n```"))
            }
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        let symbol: String
        let completion: String
    }

    /// What the field offers for this text. Pure, and run from `onChange`/the lookups rather than
    /// from `body`: filtering the whole command catalog on every keystroke was the composer's
    /// largest per-keystroke cost, and it ran again on every unrelated thread update.
    nonisolated static func matchingSuggestions(for text: String, commands: [SlashCommand], fileMatches: [String]) -> [Suggestion] {
        if text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") {
            let q = text.dropFirst()
            return commands
                .filter { $0.terminalOnly != true && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
                .prefix(12)
                .map { Suggestion(id: "/" + $0.name, title: "/" + $0.name, detail: $0.description, symbol: "command", completion: "/\($0.name) ") }
        }
        if let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") {
            let prefix = text.dropLast(last.count)
            return fileMatches.prefix(12).map {
                Suggestion(id: $0, title: $0, detail: nil, symbol: $0.hasSuffix("/") ? "folder" : "doc", completion: "\(prefix)@\($0) ")
            }
        }
        return []
    }

    /// What Esc does in the field: close the `/` or `@` list first, then stop a running turn, and
    /// otherwise whatever the field does with it.
    enum EscapeAction: Equatable { case closeSuggestions, stop, ignore }

    nonisolated static func escapeAction(suggestionsShowing: Bool, canStop: Bool) -> EscapeAction {
        if suggestionsShowing { return .closeSuggestions }
        return canStop ? .stop : .ignore
    }

    private var mentionQuery: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    /// While Claude works, an empty field offers Stop; typing turns it back into Send (adds to the turn).
    private var showStop: Bool { thread?.isRunning == true && onStop != nil && !canSend }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    var body: some View {
        // While the host isn't connected, a card says so in the field's place. The composer stays,
        // so the draft and its attachments are there when the field comes back.
        let status = ConnectionStatusCard.Status(connection.state, host: connection.host.name)
        // Above the field, not in it: it's an offer, not text you've written.
        VStack(alignment: .leading, spacing: 8) {
            if status == nil, let s = thread?.promptSuggestion, text.isEmpty {
                Button { text = s } label: {
                    Label(s, systemImage: "sparkles").lineLimit(1)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .scaledFont(.callout)
                .help("Use Suggestion")
                .glassEffectTransition(.materialize)
                .transition(.moving(.opacity.combined(with: .move(edge: .bottom)), reduceMotion: reduceMotion))
            }
            if let status {
                ConnectionStatusCard(status: status, connection: connection)
                    .glassEffectID(GlassID.field, in: glass)
            } else {
                field
            }
        }
        .animation(.snappy, value: thread?.promptSuggestion)
        // The status card and the field morph into each other as the host connects and drops.
        .animation(reduceMotion ? nil : .snappy, value: status == nil)
    }

    /// Laid out like Messages: a round + outside the field, and the field a capsule that grows with
    /// its text, with a round Send — or Stop — at its trailing end.
    private var field: some View {
        // Under a prompt card the composer is still there and still typable, just clearly not the
        // thing being asked of you: its contents dim, under the glass rather than over it.
        let dim = awaitingAnswer ? 0.7 : 1
        return HStack(alignment: .bottom, spacing: 10) {
            addButton(dim: dim)
            oneRowField
                .opacity(dim)
                // A capsule at one line; the same corner radius as the text grows makes it a rounded
                // rectangle, the way Messages' field grows.
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Layout.cardCornerRadius))
                // Says a drop here will be taken.
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: Layout.cardCornerRadius).strokeBorder(.tint, lineWidth: 2)
                    }
                }
                // The status card morphs into the field when the host connects, and back.
                .glassEffectID(GlassID.field, in: glass)
        }
        // Files and images, dropped on the field, pasted, or taken with Continuity Camera.
        .dropDestination(for: Incoming.self) { items, _ in take(items) }
        .accessibilityDropPoint(.center, description: Text("Attach to Message"))
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: dropTargeted = true
            default: dropTargeted = false
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            attach(((try? result.get()) ?? []).map(Incoming.file))
        }
        .fileDialogConfirmationLabel("Attach")
        // Its own, not New Chat's directory chooser's around it.
        .fileDialogMessage("Choose files to attach to the message.")
        // From the chat's directory, on this Mac; elsewhere wherever the panel was last.
        .fileDialogDefaultDirectory(connection.host.isLocal ? cwd.map { URL(filePath: $0, directoryHint: .isDirectory) } : nil)
        .pasteDestination(for: Incoming.self) { take($0) }
        .importableFromServices(for: Incoming.self) { items in
            take(items)
            return !items.isEmpty
        }
        // The field is where focus goes when the window opens or focus has nowhere else to be, as
        // on a chat switch; not taken from the sidebar or search while someone is using them.
        .defaultFocus($focused, true)
        .onChange(of: focused, initial: true) { onFocusChange?(focused) }
        .onAppear {
            if let draftKey {
                // The draft already holds any text delivered before the field appeared.
                appliedDelivery = drafts.delivery(for: draftKey)?.id
                if text.isEmpty { text = drafts.text(for: draftKey) }
            }
            #if DEBUG
            // Previews only: the field's text is otherwise private state.
            if text.isEmpty, !composerDraft.isEmpty { text = composerDraft }
            #endif
        }
        .onChange(of: text) {
            suggestionsClosedFor = nil
            if text.hasPrefix("/") { requestCommands() }
            refreshSuggestions()
            if let draftKey { drafts.set(text, for: draftKey) }
        }
        // Text put there from outside the field — a Shortcut's prompt — shows up in it, once. Not
        // the draft itself: observing that redrew every composer in every window per keystroke.
        .onChange(of: draftKey.flatMap { drafts.delivery(for: $0) }) { _, delivery in
            guard let delivery, delivery.id != appliedDelivery else { return }
            appliedDelivery = delivery.id
            text = delivery.text
        }
        // Only a list already fetched: asking is for when someone looks for a command.
        .onChange(of: cwd, initial: true) {
            let cached = connection.cachedCommands(cwd: cwd, thread: thread)
            commands = cached ?? []
            commandsLoaded = cached != nil
            commandsWanted = false
            refreshSuggestions()
        }
        .task(id: commandsWanted) {
            guard commandsWanted else { return }
            let list = await connection.commands(cwd: cwd, thread: thread)
            guard !Task.isCancelled else { return }
            commands = list
            commandsLoaded = connection.cachedCommands(cwd: cwd, thread: thread) != nil
            commandsWanted = false
            refreshSuggestions()
        }
        // Keyed on the query so a slow reply can't overwrite a newer one.
        .task(id: mentionQuery) {
            guard let q = mentionQuery, let cwd else {
                fileMatches = []
                refreshSuggestions()
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            fileMatches = await connection.searchFiles(cwd: cwd, query: q)
            refreshSuggestions()
        }
    }

    /// The text, and Send beside its last line: on the text's baseline, which Send's symbol shares,
    /// so the text sits level with Send at any size rather than at the bottom of the row.
    private var oneRowField: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    AttachmentStrip(attachments: images) { id in images.removeAll { $0.id == id } }
                        .equatable()
                }
                textField
            }
            sendOrStop
        }
        .padding(.leading, 16)
        // Room around Send on every side, so it sits inside the field's end rather than against it.
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    private var textField: some View {
        TextField(thread?.isRunning == true ? "Queue a message…" : placeholder, text: $text, axis: .vertical)
            .accessibilityIdentifier("composer.input")
            .textFieldStyle(.plain)
            .lineLimit(1...12)
            .focused($focused)
            .onSubmit { if appearance.sendShortcut == .returnKey { send() } }
            .onKeyPress(.return, phases: .down, action: returnPressed)
            // Esc closes the suggestion list if it's open, and otherwise stops Claude, as in the
            // CLI; with nothing running it's the field's own.
            .onKeyPress(.escape) {
                switch Self.escapeAction(suggestionsShowing: !suggestions.isEmpty,
                                         canStop: thread?.isRunning == true && onStop != nil) {
                case .closeSuggestions:
                    suggestionsClosedFor = text
                    suggestions = []
                    return .handled
                case .stop:
                    onStop?()
                    return .handled
                case .ignore:
                    return .ignored
                }
            }
            .textInputSuggestions(suggestions) { s in
                Label {
                    Text(s.title)
                    if let d = s.detail { Text(d) }
                } icon: {
                    Image(systemName: s.symbol)
                }
                .textInputCompletion(s.completion)
            }
    }

    /// Send, a round button inside the field's trailing end; Stop in its place while Claude works
    /// and the field is empty.
    /// Send springs up as it sends; Send and Stop trade places with a quick scale.
    private var sendOrStop: some View {
        ZStack {
            if showStop {
                Button("Stop", systemImage: "stop.fill") { onStop?() }
                    .labelStyle(.iconOnly)
                    .modifier(RoundAction())
                    .tint(.red)
                    .help("Stop")
                    .transition(.moving(.scale(scale: 0.5).combined(with: .opacity), reduceMotion: reduceMotion))
            } else {
                Button("Send", systemImage: thread?.isRunning == true ? "arrow.turn.down.left" : "arrow.up", action: send)
                    .accessibilityIdentifier("composer.send")
                    .labelStyle(.iconOnly)
                    .symbolEffect(.bounce.up, options: reduceMotion ? .nonRepeating.speed(0) : .default, value: sends)
                    // Send's arrow turns into Add to Turn's and back as a turn starts and ends.
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: thread?.isRunning == true)
                    .modifier(RoundAction())
                    // Not while an attachment is still being read.
                    .disabled(!canSend || awaitingAnswer || attaching > 0)
                    .help(sendHelp)
                    .transition(.moving(.scale(scale: 0.5).combined(with: .opacity), reduceMotion: reduceMotion))
            }
        }
        .animation(.snappy(duration: 0.2), value: showStop)
    }

    /// A prominent round button, as Messages draws Send.
    /// Send or Stop inside the glass field: a standard prominent circle, not glass on glass.
    private struct RoundAction: ViewModifier {
        func body(content: Content) -> some View {
            content
                .fontWeight(.bold)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
        }
    }

    private var sendHelp: String {
        if awaitingAnswer { return "Answer the request above first" }
        return thread?.isRunning == true ? "Add your message to the current turn" : "Send your message"
    }

    /// The commands for this folder or chat, from what's been fetched, or asked for if there's
    /// nothing (or the list went stale when a turn ended).
    private func requestCommands() {
        if let cached = connection.cachedCommands(cwd: cwd, thread: thread) {
            if !commandsLoaded || cached != commands {
                commands = cached
                commandsLoaded = true
            }
        } else if !commandsWanted {
            commandsWanted = true
        }
    }

    private func refreshSuggestions() {
        suggestions = text == suggestionsClosedFor ? []
            : Self.matchingSuggestions(for: text, commands: commands, fileMatches: fileMatches)
    }

    /// The + menu, as the desktop app has it: attach, mention a file, or browse the commands
    /// that typing / offers, for someone who doesn't know them yet.
    private func addButton(dim: Double) -> some View {
        Menu {
            Button("Attach Files…", systemImage: "paperclip") { choosingFiles = true }
            Button("Mention a File", systemImage: "at") { insert("@") }
                .disabled(cwd == nil)
            let offered = commands.filter { $0.terminalOnly != true }
            Menu("Commands", systemImage: "command") {
                ForEach(offered, id: \.name) { command in
                    Button { insert("/\(command.name) ") } label: {
                        Text("/" + command.name)
                        Text(command.description)
                    }
                }
                if !commandsLoaded {
                    // Asked for as the pointer reaches +; this stands in until they arrive.
                    Text("Loading…")
                        .onAppear { requestCommands() }
                }
            }
            .disabled(commandsLoaded && offered.isEmpty)
        } label: {
            // Glass on the label itself: on macOS 27 the glass button style draws a flat circle on
            // a `Menu`, not glass. As tall as the field beside it at one line.
            Label("Add", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .opacity(dim)
                .frame(width: 34, height: 34)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        // About to open the menu, whose Commands are asked for only now.
        .onHover { if $0 { requestCommands() } }
        .help("Add")
        .accessibilityIdentifier("composer.add")
    }

    /// Puts `token` where typing it would, and the cursor after it.
    private func insert(_ token: String) {
        if token.hasPrefix("/") {
            // A command goes first, in place of one already there.
            var rest = Substring(text)
            if rest.hasPrefix("/") { rest = rest.drop { $0 != " " } }
            text = token + rest.trimmingCharacters(in: .whitespaces)
        } else {
            text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + token
        }
        focused = true
    }

    /// Return and its modifiers, as Settings ▸ General ▸ Send With has them: Return sends and
    /// Shift- or Option-Return starts a line, or Command-Return sends and Return starts a line.
    private func returnPressed(_ press: KeyPress) -> KeyPress.Result {
        // The field's own new line, so it's an edit the field can undo and an input method's
        // marked text is committed first; setting the text around it did neither.
        let newLine = { _ = NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil) }
        switch appearance.sendShortcut {
        case .returnKey:
            // Plain Return reaches `onSubmit`; Option-Return is the field's own new line.
            guard press.modifiers.contains(.shift) else { return .ignored }
            newLine()
            return .handled
        case .commandReturn:
            if press.modifiers.contains(.command) {
                send()
            } else if !press.modifiers.contains(.option) {
                newLine()
            } else {
                return .ignored
            }
            return .handled
        }
    }

    private func send() {
        guard canSend, !awaitingAnswer, attaching == 0 else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var input: [UserInput] = []
        if !trimmed.isEmpty { input.append(.text(.init(text: trimmed))) }
        for attachment in images { input.append(attachment.input) }
        text = ""
        images = []
        sends += 1
        Task { await submit(input) }
    }

    /// What the field takes from outside it: a file (by URL), or an image that isn't one, such as
    /// a screenshot's thumbnail or a photo from Continuity Camera.
    enum Incoming: Transferable {
        case file(URL)
        case image(Data)

        /// An image first: an image dragged from a web page carries its URL too, and would
        /// otherwise arrive as a link.
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(importedContentType: .image) { Incoming.image($0) }
            ProxyRepresentation(importing: { (url: URL) in Incoming.file(url) })
        }
    }

    private func take(_ items: [Incoming]) {
        var reads: [Incoming] = []
        for item in items {
            switch item {
            case .file(let url) where url.isFileURL:
                if url.hasDirectoryPath, let takesDirectory { takesDirectory(url.path) } else { reads.append(item) }
            case .file(let url):
                // A web link, written into the message.
                text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + url.absoluteString + " "
            case .image:
                reads.append(item)
            }
        }
        attach(reads)
    }

    /// Reads files and prepares images off the main actor, taking them in the order given: a file
    /// read, or a photo decoded and encoded again, held up the main thread for as long as it took.
    private func attach(_ items: [Incoming]) {
        guard !items.isEmpty else { return }
        let hostIsLocal = connection.host.isLocal
        attaching += 1
        Task {
            for item in items {
                switch await Self.prepare(item, hostIsLocal: hostIsLocal) {
                case .attachment(let attachment): images.append(attachment)
                case .mention(let path): text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@" + path + " "
                case .nothing: break
                }
            }
            attaching -= 1
        }
    }

    /// What a dropped, pasted or chosen file or image becomes.
    enum Prepared: Sendable {
        case attachment(Attachment)
        /// Mentioned by path, for Claude to read.
        case mention(String)
        /// An image that couldn't be read.
        case nothing
    }

    @concurrent
    private nonisolated static func prepare(_ item: Incoming, hostIsLocal: Bool) async -> Prepared {
        switch item {
        case .file(let url): read(file: url, hostIsLocal: hostIsLocal)
        case .image(let data): prepareImage(data).map { .attachment($0) } ?? .nothing
        }
    }

    /// An image is attached; any other file is mentioned by path, for Claude to read.
    nonisolated static func read(file url: URL, hostIsLocal: Bool) -> Prepared {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            return prepareImage(data).map { .attachment($0) } ?? .nothing
        } else if type?.conforms(to: .pdf) == true, let data = try? Data(contentsOf: url) {
            return .attachment(Attachment(kind: .pdf(base64: data.base64EncodedString(), name: url.lastPathComponent)))
        } else if hostIsLocal {
            // This Mac's Claude reads the file where it is.
            return .mention(url.path)
        } else if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxTextAttachment,
                  let content = try? String(contentsOf: url, encoding: .utf8), content.utf8.count <= maxTextAttachment {
            // Another host can't see this Mac's paths, so the text goes with the message. Its size
            // is checked before it's read: a log can be gigabytes.
            return .attachment(Attachment(kind: .text(content, name: url.lastPathComponent)))
        } else {
            return .mention(url.path)
        }
    }

    /// The most text sent with a message in place of a file another host can't read.
    nonisolated static let maxTextAttachment = 256 * 1024
    /// The long edge Claude reads an image at; a larger one is scaled down to it before it's sent.
    nonisolated static let maxImageEdge = 1568
    /// A chip is 56 points square: its picture's short edge, at 2x.
    nonisolated static let chipPixels = 112

    enum ImagePlan: Equatable {
        /// Sent as it came.
        case keep(UserInput.Image.MediaType)
        /// Drawn again with this long edge, and encoded as JPEG or PNG.
        case scale(longEdge: Int, jpeg: Bool)
    }

    /// An image Claude reads is sent as it came, unless it's larger than Claude reads: it used to be
    /// decoded and sent as a full-size PNG, and a 12-megapixel photo was tens of megabytes. Anything
    /// else, or larger, is drawn again at most that size: a photo as JPEG, the rest as PNG.
    nonisolated static func imagePlan(type: UTType?, width: Int, height: Int) -> ImagePlan {
        let longEdge = max(width, height)
        let sent: UserInput.Image.MediaType? = switch type {
        case .png?: .imagePng
        case .jpeg?: .imageJpeg
        case .gif?: .imageGif
        case .webP?: .imageWebp
        default: nil
        }
        if let sent, longEdge <= maxImageEdge { return .keep(sent) }
        let photo = type.map { $0.conforms(to: .jpeg) || $0.conforms(to: .heic) || $0.conforms(to: .heif) } ?? false
        return .scale(longEdge: min(longEdge, maxImageEdge), jpeg: photo)
    }

    /// The image as it's sent, with its chip's picture; nil when it isn't an image ImageIO reads.
    nonisolated static func prepareImage(_ data: Data) -> Attachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        // Its short edge fills the chip, so a panorama's is wider than 112.
        let chip = downsampled(source, longEdge: min(max(width, height),
                                                     chipPixels * max(width, height) / min(width, height), 1024))
        switch imagePlan(type: type, width: width, height: height) {
        case .keep(let mediaType):
            return Attachment(kind: .image(base64: data.base64EncodedString(), mediaType: mediaType), thumbnail: chip)
        case .scale(let longEdge, let jpeg):
            guard let image = downsampled(source, longEdge: longEdge), let encoded = encode(image, jpeg: jpeg) else { return nil }
            return Attachment(kind: .image(base64: encoded.base64EncodedString(), mediaType: jpeg ? .imageJpeg : .imagePng),
                              thumbnail: chip)
        }
    }

    /// The image at most `longEdge` pixels on its long edge, upright, decoded now rather than when
    /// it's first drawn.
    nonisolated static func downsampled(_ source: CGImageSource, longEdge: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private nonisolated static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let data = NSMutableData()
        let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The attachments over the text, each with its Remove button. Its own view, compared by the
/// attachments' ids, so typing in the field doesn't build the chips again.
private struct AttachmentStrip: View, Equatable {
    let attachments: [Composer.Attachment]
    let remove: (UUID) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.attachments.elementsEqual(b.attachments) { $0.id == $1.id }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(attachments) { attachment in
                    chip(attachment)
                        .overlay(alignment: .topTrailing) {
                            // Named for what it removes: several can be attached.
                            Button("Remove \(attachment.title)", systemImage: "xmark.circle.fill") { remove(attachment.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                }
            }
        }
        // Still while the chips fit.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    @ViewBuilder private func chip(_ attachment: Composer.Attachment) -> some View {
        switch attachment.kind {
        case .image:
            if let thumbnail = attachment.thumbnail {
                Image(thumbnail, scale: 2, label: Text("Attached Image"))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityIgnoresInvertColors()
            }
        case .pdf(_, let name), .text(_, let name):
            VStack(spacing: 4) {
                Image(systemName: { if case .pdf = attachment.kind { "doc.richtext" } else { "doc.text" } }())
                    .font(.title2)
                Text(name).font(.caption2).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .frame(width: 72, height: 56)
            .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            .help(name)
        }
    }
}

#if DEBUG
#Preview("Idle") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleIdleChat()
    GlassEffectContainer {
        Composer(connection: connection, cwd: thread.cwd, thread: thread, onStop: {}, submit: { _ in })
    }
    .padding(20)
    .frame(width: 560)
}

#Preview("Running (shows Stop)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleRunningTurn()
    GlassEffectContainer {
        Composer(connection: connection, cwd: thread.cwd, thread: thread, onStop: {}, submit: { _ in })
    }
    .padding(20)
    .frame(width: 560)
}

/// A draft with a request still to answer: the text is kept, Send is off, Stop is still there.
#Preview("Awaiting an answer (draft kept)") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.samplePendingPermission()
    GlassEffectContainer {
        Composer(connection: connection, cwd: thread.cwd, thread: thread, awaitingAnswer: true, onStop: {}, submit: { _ in })
    }
    .environment(\.composerDraft, "…and once that's done, run the package tests")
    .padding(20)
    .frame(width: 560)
}

#Preview("New chat (no thread yet)") {
    let connection = HostConnection.sample()
    GlassEffectContainer {
        Composer(connection: connection, cwd: nil, placeholder: "Choose a directory, then ask Claude…", submit: { _ in })
    }
    .padding(20)
    .frame(width: 560)
}

/// Send stays by the last line as the text grows, and the text by Send at any size.
#Preview("Several lines, and bigger text") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleIdleChat()
    VStack(spacing: 20) {
        GlassEffectContainer {
            Composer(connection: connection, cwd: thread.cwd, thread: thread, submit: { _ in })
        }
        .environment(\.composerDraft, "Rename the helper,\nthen update its callers,\nand run the package tests")
        GlassEffectContainer {
            Composer(connection: connection, cwd: thread.cwd, thread: thread, submit: { _ in })
        }
        .scaledFont(.body)
        .environment(\.textScale, 1.5)
    }
    .padding(20)
    .frame(width: 560)
}

#endif
