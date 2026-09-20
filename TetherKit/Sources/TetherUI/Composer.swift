import SwiftUI
import TetherKit
import TetherProtocol
import UniformTypeIdentifiers

/// Prompt field: native multi-line TextField (Return sends, ⌥Return adds a line) with native
/// input suggestions for `/` commands and `@` file mentions, image attachments, and send-while-running.
struct Composer: View {
    let connection: HostConnection
    let cwd: String?
    var thread: ThreadModel?
    var placeholder = "Ask Claude…"
    var onStop: (() -> Void)?
    let submit: ([UserInput]) async -> Void

    @State private var text = ""
    @State private var images: [Attachment] = []
    @State private var commands: [SlashCommand] = []
    @State private var fileMatches: [String] = []
    @FocusState private var focused: Bool

    struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let mediaType: String
    }

    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let symbol: String
        let completion: String
    }

    private var suggestions: [Suggestion] {
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
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty { attachments }
            if let s = thread?.promptSuggestion, text.isEmpty {
                Button { text = s } label: { Label(s, systemImage: "sparkles").lineLimit(1) }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField(thread?.isRunning == true ? "Send a message while Claude works…" : placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .focused($focused)
                .onSubmit(send)
                .textInputSuggestions(suggestions) { s in
                    Label {
                        Text(s.title)
                        if let d = s.detail { Text(d) }
                    } icon: {
                        Image(systemName: s.symbol)
                    }
                    .textInputCompletion(s.completion)
                }
                .padding(.top, 4)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if showStop {
                    Button("Stop", systemImage: "stop.fill") { onStop?() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .tint(.red)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop (⌘.)")
                } else {
                    Button("Send", systemImage: thread?.isRunning == true ? "arrow.turn.down.left" : "arrow.up", action: send)
                        .labelStyle(.iconOnly)
                        .fontWeight(.semibold)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!canSend)
                        .help(thread?.isRunning == true ? "Add to the running turn" : "Send")
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: drop)
        .onPasteCommand(of: [.png, .tiff, .jpeg], perform: { _ = drop($0) })
        .onAppear { focused = true }
        .task(id: cwd) {
            if let thread { commands = await connection.commands(for: thread) }
        }
        // Keyed on the query so each keystroke cancels the last search instead of racing it —
        // otherwise a slow reply can land after a newer one and rewrite the list.
        .task(id: mentionQuery) {
            guard let q = mentionQuery, let cwd else { fileMatches = []; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            fileMatches = await connection.searchFiles(cwd: cwd, query: q)
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(images) { img in
                    if let ns = NSImage(data: img.data) {
                        Image(nsImage: ns)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay(alignment: .topTrailing) {
                                Button("Remove", systemImage: "xmark.circle.fill") { images.removeAll { $0.id == img.id } }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                            }
                    }
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var input: [UserInput] = []
        if !trimmed.isEmpty { input.append(.text(.init(text: trimmed))) }
        for img in images { input.append(.image(.init(mediaType: .init(rawValue: img.mediaType), data: img.data.base64EncodedString()))) }
        text = ""
        images = []
        Task { await submit(input) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let data = try? Data(contentsOf: url) {
                            add(image: data)
                        } else {
                            text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@" + url.path + " "
                        }
                    }
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

    private func add(image data: Data) {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
        images.append(Attachment(data: png, mediaType: "image/png"))
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

#Preview("New chat (no thread yet)") {
    let connection = HostConnection.sample()
    GlassEffectContainer {
        Composer(connection: connection, cwd: nil, placeholder: "Choose a folder, then ask Claude…", submit: { _ in })
    }
    .padding(20)
    .frame(width: 560)
}

#endif
