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

    @Environment(\.composerDraft) private var composerDraft
    @Environment(\.composerDrafts) private var drafts
    @Environment(\.appearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var images: [Attachment] = []
    @State private var commands: [SlashCommand] = []
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

    private enum GlassID: Hashable { case field }

    /// Something going with the message besides its text.
    struct Attachment: Identifiable {
        let id = UUID()
        let kind: Kind

        enum Kind {
            /// PNG data.
            case image(Data)
            /// A PDF, sent as a document Claude reads.
            case pdf(Data, name: String)
            /// A text file's contents, for a host that can't read the file where it is.
            case text(String, name: String)
        }

        var input: UserInput {
            switch kind {
            case .image(let data):
                .image(.init(mediaType: .init(rawValue: "image/png"), data: data.base64EncodedString()))
            case .pdf(let data, let name):
                .document(.init(mediaType: .applicationPdf, data: data.base64EncodedString(), name: name))
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
    }

    /// Laid out like Messages: a round + outside the field, and the field a capsule that grows with
    /// its text, with a round Send — or Stop — at its trailing end.
    private var field: some View {
        // Under a prompt card the composer is still there and still typable, just clearly not the
        // thing being asked of you: its contents dim, under the glass rather than over it.
        let dim = awaitingAnswer ? 0.7 : 1
        return HStack(alignment: .bottom, spacing: 10) {
            addButton.opacity(dim)
            oneRowField
                .opacity(dim)
                // A capsule at one line; the same corner radius as the text grows makes it a rounded
                // rectangle, the way Messages' field grows.
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Layout.cardCornerRadius))
                // The status card morphs into the field when the host connects, and back.
                .glassEffectID(GlassID.field, in: glass)
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: drop)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] { add(file: url) }
        }
        .fileDialogConfirmationLabel("Attach")
        // From the chat's directory, on this Mac; elsewhere wherever the panel was last.
        .fileDialogDefaultDirectory(connection.host.isLocal ? cwd.map { URL(filePath: $0, directoryHint: .isDirectory) } : nil)
        .onPasteCommand(of: [.png, .tiff, .jpeg], perform: { _ = drop($0) })
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
        .task(id: cwd) {
            commands = await connection.commands(cwd: cwd, thread: thread)
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
                if !images.isEmpty { attachments }
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
                    .keyboardShortcut(".", modifiers: .command)
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
                    .disabled(!canSend || awaitingAnswer)
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

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(images) { attachment in
                    chip(attachment)
                        .overlay(alignment: .topTrailing) {
                            Button("Remove", systemImage: "xmark.circle.fill") { images.removeAll { $0.id == attachment.id } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                }
            }
        }
        // Still while the chips fit.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    @ViewBuilder private func chip(_ attachment: Attachment) -> some View {
        switch attachment.kind {
        case .image(let data):
            if let ns = NSImage(data: data) {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 8))
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

    private func refreshSuggestions() {
        suggestions = text == suggestionsClosedFor ? []
            : Self.matchingSuggestions(for: text, commands: commands, fileMatches: fileMatches)
    }

    /// The + menu, as the desktop app has it: attach, mention a file, or browse the commands
    /// that typing / offers, for someone who doesn't know them yet.
    private var addButton: some View {
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
            }
            .disabled(offered.isEmpty)
        } label: {
            // Glass on the label itself: on macOS 27 the glass button style draws a flat circle on
            // a `Menu`, not glass. As tall as the field beside it at one line.
            Label("Add", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
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
        guard canSend, !awaitingAnswer else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var input: [UserInput] = []
        if !trimmed.isEmpty { input.append(.text(.init(text: trimmed))) }
        for attachment in images { input.append(attachment.input) }
        text = ""
        images = []
        sends += 1
        Task { await submit(input) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add(file: url) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let tiff = img.tiffRepresentation else { return }
                    Task { @MainActor in add(image: tiff) }
                }
            }
        }
        return true
    }

    /// An image is attached; any other file is mentioned by path, for Claude to read.
    private func add(file url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            add(image: data)
        } else if type?.conforms(to: .pdf) == true, let data = try? Data(contentsOf: url) {
            images.append(Attachment(kind: .pdf(data, name: url.lastPathComponent)))
        } else if connection.host.isLocal {
            // This Mac's Claude reads the file where it is.
            text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@" + url.path + " "
        } else if let content = try? String(contentsOf: url, encoding: .utf8), content.utf8.count <= 256 * 1024 {
            // Another host can't see this Mac's paths, so the text goes with the message.
            images.append(Attachment(kind: .text(content, name: url.lastPathComponent)))
        } else {
            text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@" + url.path + " "
        }
    }

    private func add(image data: Data) {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
        images.append(Attachment(kind: .image(png)))
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
