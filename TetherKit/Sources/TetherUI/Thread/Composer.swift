import SwiftUI
import TetherKit
import TetherProtocol
import UniformTypeIdentifiers

/// Prompt field: native multi-line TextField (Return or ⌘Return sends, per Settings) with native
/// input suggestions for `/` commands and `@` file mentions, image attachments, and send-while-running.
///
/// The only thread properties it reads are `promptSuggestion` and `isRunning`, both of which change
/// at turn boundaries rather than per streamed delta, so a running turn doesn't re-render the field.
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
    /// Beside Send inside the field: the chat's context ring.
    var accessory: AnyView?
    let submit: ([UserInput]) async -> Void

    @Environment(\.composerDraft) private var composerDraft
    @Environment(\.composerDrafts) private var drafts
    @Environment(\.appearance) private var appearance
    @State private var text = ""
    @State private var images: [Attachment] = []
    @State private var commands: [SlashCommand] = []
    @State private var fileMatches: [String] = []
    @State private var suggestions: [Suggestion] = []
    @State private var choosingFiles = false
    @FocusState private var focused: Bool

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

    private var mentionQuery: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    /// While Claude works, an empty field offers Stop; typing turns it back into Send (adds to the turn).
    private var showStop: Bool { thread?.isRunning == true && onStop != nil && !canSend }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    var body: some View {
        // Above the field, not in it: it's an offer, not text you've written.
        VStack(alignment: .leading, spacing: 8) {
            if let s = thread?.promptSuggestion, text.isEmpty {
                Button { text = s } label: {
                    Label(s, systemImage: "sparkles").lineLimit(1)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .scaledFont(.callout)
                .help("Put this suggestion in the message field")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            field
        }
        .animation(.snappy, value: thread?.promptSuggestion)
    }

    /// Laid out like Messages: a round + outside the field, and the field a capsule that grows with
    /// its text, with a round Send — or Stop — at its trailing end.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 10) {
            addButton
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    if !images.isEmpty { attachments }
                    TextField(thread?.isRunning == true ? "Send a message while Claude works…" : placeholder, text: $text, axis: .vertical)
                        .accessibilityIdentifier("composer.input")
                        .textFieldStyle(.plain)
                        .lineLimit(1...12)
                        .focused($focused)
                        .onSubmit { if appearance.sendShortcut == .returnKey { send() } }
                        .onKeyPress(.return, phases: .down, action: returnPressed)
                        // Esc stops Claude, as in the CLI; with nothing running it's the field's own.
                        .onKeyPress(.escape) {
                            guard thread?.isRunning == true, let onStop else { return .ignored }
                            onStop()
                            return .handled
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
                        // A line of text no taller than Send, so one line leaves the field as tall as
                        // the + beside it and Send sits evenly inside.
                        .padding(.vertical, 4)
                }
                if let accessory { accessory }
                sendOrStop
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            // A capsule at one line; the same corner radius as the text grows makes it a rounded
            // rectangle, the way Messages' field grows.
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        // Under a prompt card the composer is still there and still typable, just clearly not the
        // thing being asked of you.
        .opacity(awaitingAnswer ? 0.7 : 1)
        .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: drop)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] { add(file: url) }
        }
        .onPasteCommand(of: [.png, .tiff, .jpeg], perform: { _ = drop($0) })
        .onAppear {
            focused = true
            if text.isEmpty, let draftKey { text = drafts.text(for: draftKey) }
            #if DEBUG
            // Previews only: the field's text is otherwise private state.
            if text.isEmpty, !composerDraft.isEmpty { text = composerDraft }
            #endif
        }
        .onChange(of: text) {
            refreshSuggestions()
            if let draftKey { drafts.set(text, for: draftKey) }
        }
        // A draft put there from outside the field — a Shortcut's prompt — shows up in it.
        .onChange(of: draftKey.map { drafts.text(for: $0) } ?? "") { _, draft in
            if !draft.isEmpty, draft != text { text = draft }
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

    /// Send, a round button inside the field's trailing end; Stop in its place while Claude works
    /// and the field is empty.
    @ViewBuilder private var sendOrStop: some View {
        if showStop {
            Button("Stop", systemImage: "stop.fill") { onStop?() }
                .labelStyle(.iconOnly)
                .modifier(RoundAction())
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the current turn")
        } else {
            Button("Send", systemImage: thread?.isRunning == true ? "arrow.turn.down.left" : "arrow.up", action: send)
                .accessibilityIdentifier("composer.send")
                .labelStyle(.iconOnly)
                .modifier(RoundAction())
                .disabled(!canSend || awaitingAnswer)
                .help(sendHelp)
        }
    }

    /// A prominent round button, as Messages draws Send.
    /// Send or Stop inside the glass field: a standard prominent circle, not glass on glass.
    private struct RoundAction: ViewModifier {
        func body(content: Content) -> some View {
            content
                .fontWeight(.bold)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
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
        suggestions = Self.matchingSuggestions(for: text, commands: commands, fileMatches: fileMatches)
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
            // Glass on the label itself: a glass button style doesn't reach a `Menu`. As tall as
            // the field beside it at one line.
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
        .help("Attach files, mention one, or use a command")
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
        Composer(connection: connection, cwd: nil, placeholder: "Choose a folder, then ask Claude…", submit: { _ in })
    }
    .padding(20)
    .frame(width: 560)
}

#endif
