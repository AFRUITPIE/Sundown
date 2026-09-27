import SwiftUI
import TetherKit
import TetherProtocol

/// What differs from the last commit in the chat's folder, file by file, as the desktop app's diff
/// view shows it. Click a line to leave a comment on it; the comments go to Claude together as one
/// message (⌘Return). Refreshed after each turn, since that's when Claude changes files.
struct ChangesPane: View {
    let thread: ThreadModel
    let connection: HostConnection
    @State private var state: Loaded<WorkingChanges?>
    @State private var comments: [ReviewComment] = []
    @State private var commenting: ReviewComment?
    @State private var draft = ""
    /// Where the repository is on this Mac, which git's paths are relative to, for Open and Show
    /// in Finder; nil on another host. Found when the changes are read, not in a body.
    @State private var repository: String?
    /// False when a preview seeded the changes.
    private let fetches: Bool

    init(thread: ThreadModel, connection: HostConnection, changes: WorkingChanges? = nil) {
        self.thread = thread
        self.connection = connection
        _state = State(initialValue: changes.map { .ready($0) } ?? .loading)
        _repository = State(initialValue: changes != nil && connection.host.isLocal ? thread.cwd : nil)
        fetches = changes == nil
    }

    struct ReviewComment: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let line: Int
        var text: String
    }

    var body: some View {
        content
            .safeAreaBar(edge: .bottom) { actions }
            .task(id: Key(thread: thread.id, turns: thread.turns.count)) {
                guard fetches else { return }
                await refresh()
            }
            .alert("Comment on Line \(commenting?.line ?? 0)", isPresented: Binding(get: { commenting != nil }, set: { if !$0 { commenting = nil } })) {
                TextField("Comment", text: $draft)
                Button("Add") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if var comment = commenting, !text.isEmpty {
                        comment.text = text
                        comments.append(comment)
                    }
                    commenting = nil
                }
                Button("Cancel", role: .cancel) { commenting = nil }
            } message: {
                Text(commenting?.path ?? "")
            }
    }

    private struct Key: Equatable { let thread: String; let turns: Int }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Read Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await refresh() } }
            }
        case .ready(nil):
            InspectorEmptyState("Not a Git Repository", symbol: "folder")
        case .ready(let changes?) where changes.files.isEmpty:
            InspectorEmptyState("No Changes", symbol: "checkmark.circle")
        case .ready(let changes?):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    summary(changes)
                    ForEach(changes.files) { file in
                        FileSection(file: file, location: repository.map { ($0 as NSString).appendingPathComponent(file.path) },
                                    comments: comments.filter { $0.path == file.path },
                                    comment: { line in
                                        draft = ""
                                        commenting = ReviewComment(path: file.path, line: line, text: "")
                                    },
                                    remove: { c in comments.removeAll { $0.id == c.id } })
                    }
                }
                .padding(12)
            }
        }
    }

    private func summary(_ changes: WorkingChanges) -> some View {
        HStack(spacing: 6) {
            Text(changes.files.count == 1 ? "1 file" : "\(changes.files.count) files")
            Text("+\(changes.added)").foregroundStyle(.green)
            Text("−\(changes.removed)").foregroundStyle(.red)
            Spacer()
            if let branch = changes.branch {
                Label(branch, systemImage: "arrow.triangle.branch").foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Read the changes again")
        }
        .font(.callout)
        .monospacedDigit()
    }

    private var actions: some View {
        HStack {
            Button("Ask Claude to Review") { send("/review") }
                .help("Ask Claude to review these changes")
            Spacer()
            Button(comments.count < 2 ? "Send Comment" : "Send \(comments.count) Comments") {
                let lines = comments.map { "- `\($0.path):\($0.line)` — \($0.text)" }
                send("Please address these review comments on the working tree:\n\n" + lines.joined(separator: "\n"))
                comments = []
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(comments.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(thread.cwd == nil)
    }

    private func send(_ text: String) {
        Task { await connection.send(thread, input: [.text(.init(text: text))]) }
    }

    private func refresh() async {
        guard let cwd = thread.cwd else {
            state = .ready(nil)
            return
        }
        do {
            let changes = try await connection.workingChanges(cwd: cwd)
            // A chat can work in a folder below the repository's top, and git's paths start there.
            repository = connection.host.isLocal ? cwd.enclosingRepository ?? cwd : nil
            state = .ready(changes)
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// One file: its name and counts, opening to its hunks. On this Mac, Open (in the editor chosen in
/// Settings ▸ General) is on the row while the pointer is over it, and in its context menu.
private struct FileSection: View {
    let file: FileDiff
    /// The file on this Mac; nil on another host.
    let location: String?
    let comments: [ChangesPane.ReviewComment]
    let comment: (Int) -> Void
    let remove: (ChangesPane.ReviewComment) -> Void
    @State private var expanded = true
    @State private var hovering = false
    @Environment(\.openFilesWith) private var editor

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if file.isBinary {
                Text("Binary File").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                // Code keeps its shape: a long line scrolls sideways rather than wrapping.
                ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    // At least as wide as the pane, so a short file's lines are highlighted across it.
                    Color.clear.frame(height: 0).containerRelativeFrame(.horizontal)
                    ForEach(file.hunks) { hunk in
                        Text(hunk.header)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.vertical, 3)
                        ForEach(hunk.lines) { line in
                            LineRow(line: line, comment: comment)
                            ForEach(comments.filter { $0.line == line.newNumber ?? line.oldNumber }) { c in
                                CommentRow(comment: c) { remove(c) }
                            }
                        }
                    }
                }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .background(.fill.quinary, in: .rect(cornerRadius: 6))
                .clipShape(.rect(cornerRadius: 6))
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent).fontWeight(.medium)
                    let folder = (file.path as NSString).deletingLastPathComponent
                    if !folder.isEmpty { Text(folder).font(.caption).foregroundStyle(.secondary).truncationMode(.middle) }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if let location {
                    // Kept in the layout while hidden, so the counts don't move under the pointer.
                    Button(editor.openTitle, systemImage: "arrow.up.forward.app") { editor.open(location) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(editor.openTitle)
                        .opacity(hovering ? 1 : 0)
                }
                Text("+\(file.added)").foregroundStyle(.green)
                Text("−\(file.removed)").foregroundStyle(.red)
            }
            .font(.callout)
            .monospacedDigit()
            .help(file.oldPath.map { "Renamed from \($0)" } ?? file.path)
            .onHover { hovering = $0 }
            .contextMenu {
                if let location {
                    Button(editor.openTitle) { editor.open(location) }
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(location, inFileViewerRootedAtPath: "") }
                    Divider()
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(location ?? file.path, forType: .string)
                }
            }
        }
    }
}

private struct LineRow: View {
    let line: FileDiff.Line
    let comment: (Int) -> Void

    private var number: Int? { line.newNumber ?? line.oldNumber }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
            Text(sign).foregroundStyle(.secondary)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.monospaced())
        .padding(.trailing, 6)
        .padding(.vertical, 1)
        .background(background)
        .contentShape(.rect)
        .onTapGesture { if let number { comment(number) } }
        .contextMenu {
            if let number { Button("Comment on Line \(number)…") { comment(number) } }
        }
        .help("Click to comment on this line")
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        case .context: .clear
        }
    }
}

private struct CommentRow: View {
    let comment: ChangesPane.ReviewComment
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble").foregroundStyle(.tint)
            Text(comment.text).lineLimit(nil).frame(maxWidth: 360, alignment: .leading)
            Button("Remove Comment", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(8)
        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 6))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

#if DEBUG
extension WorkingChanges {
    static let sample = WorkingChanges(branch: "dev", files: UnifiedDiff.parse("""
    diff --git a/TetherKit/Sources/TetherUI/RootView.swift b/TetherKit/Sources/TetherUI/RootView.swift
    index 1111111..2222222 100644
    --- a/TetherKit/Sources/TetherUI/RootView.swift
    +++ b/TetherKit/Sources/TetherUI/RootView.swift
    @@ -38,6 +38,9 @@ public struct RootView: View {
                 .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
             } detail: {
                 DetailView(window: window)
    +                // Declared, like the other columns'.
    +                .navigationSplitViewColumnWidth(min: 520, ideal: 720)
    +                .navigationTitle(window.selectedThread?.title ?? "New Chat")
    -                .navigationTitle(window.title)
                     .navigationSubtitle(window.subtitle)
    """) + [.added(path: "TetherKit/Sources/TetherUI/Inspector/ChangesPane.swift", content: "import SwiftUI\n\nstruct ChangesPane: View {\n}\n")])
}

#Preview("Changes") {
    inspectorPreview {
        ThreadInspector(thread: .sampleIdleChat(), connection: .sample(), pane: .constant(.changes))
            .environment(\.previewChanges, .sample)
    }
}
#endif
