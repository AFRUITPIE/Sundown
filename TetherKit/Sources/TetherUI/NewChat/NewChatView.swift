import SwiftUI
import TetherKit
import TetherProtocol

/// Compose a new chat: choose the working directory, then send the first message. The host is
/// the one the sidebar shows.
struct NewChatView: View {
    @Bindable var window: WindowModel
    @State private var choosingFolder = false
    /// What git says about the folder; nil until the host answers, or when it can't.
    @State private var git: FolderGit?
    @Environment(\.appearsActive) private var appearsActive
    /// False when a preview seeded `git`: the preview host never answers.
    private let readsGit: Bool

    /// Whether the folder is in a git repository, and the branch checked out there (nil when HEAD
    /// is detached).
    struct FolderGit: Equatable {
        var isRepository: Bool
        var branch: String?
    }

    init(window: WindowModel) {
        self.init(window: window, git: nil, readsGit: true)
    }

    #if DEBUG
    /// For previews: the folder's git state as given, never asked of the host.
    init(window: WindowModel, previewGit: FolderGit?) {
        self.init(window: window, git: previewGit, readsGit: false)
    }
    #endif

    private init(window: WindowModel, git: FolderGit?, readsGit: Bool) {
        _window = Bindable(window)
        _git = State(initialValue: git)
        self.readsGit = readsGit
    }

    /// The same host the sidebar shows, so its chats and this draft always agree.
    private var connection: HostConnection? { window.connection }

    var body: some View {
        // No Form: a scrolling Form draws a hard scroll edge under the toolbar, which a chat
        // doesn't have. The folder sits where a chat's status strip goes. A host that isn't
        // connected is said once, by the status card in the composer's place, as in a chat; the
        // folder waits with the draft until it is.
        let starting = window.starting
        content(starting)
            .safeAreaBar(edge: .bottom) {
                if let connection {
                    VStack(alignment: .leading, spacing: 10) {
                        // Where the chat works is settled once it's sent.
                        if connection.state == .connected, starting == nil { chips(connection) }
                        Group {
                            if let error = window.draftError, starting == nil {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            // The same composer throughout, so a start that fails puts its prompt
                            // and attachments back in it. While the chat starts it's that chat's:
                            // Stop, and a message sent goes once the chat has started.
                            GlassEffectContainer(spacing: 10) {
                                Composer(connection: connection, cwd: window.draftDirectory,
                                         thread: starting?.placeholder,
                                         draftKey: "new-chat:\(window.hostID)",
                                         placeholder: window.draftDirectory == nil ? "Choose a directory, then ask Claude…" : "Ask Claude…",
                                         onStop: starting.map { _ in { window.stopStarting() } },
                                         submit: { input in await start(connection, input) },
                                         // Dropped on the field too, a directory is where the chat starts.
                                         takesDirectory: connection.host.isLocal && starting == nil ? { choose($0) } : nil)
                            }
                        }
                        // The chips are controls, so they keep the system's size; what's written here scales.
                        .scaledFont(.body)
                    }
                    .padding(.bottom, Layout.composerBottom)
                    // The same column the transcript and its bottom bar use, so the composer doesn't
                    // move sideways when the first message turns this into a chat.
                    .readingColumn()
                }
            }
            .directoryChooser(isPresented: $choosingFolder, connection: connection, current: window.draftDirectory) { choose($0) }
            // `AppModel` seeds the folder with the host's first project; these fill it when the
            // projects arrived after that.
            // A folder dragged from Finder is where the chat starts; this Mac's folders only.
            .dropDestination(for: URL.self, isEnabled: connection?.host.isLocal == true && starting == nil) { urls, _ in
                if let folder = urls.first(where: \.hasDirectoryPath) { choose(folder.path) }
            }
            .accessibilityDropPoint(.center, description: Text("Work in Directory"))
            .onAppear { useFirstProjectIfUnset() }
            .onChange(of: connection?.projects.first?.cwd) { useFirstProjectIfUnset() }
            // Read again when the window comes back to the front, since the branch may have been
            // switched in a terminal meanwhile.
            .task(id: GitKey(folder: window.draftDirectory, connected: connection?.state == .connected, active: appearsActive)) {
                await readGit()
            }
            // What the host's Claude Code would start this chat with, for the session menus to say.
            .task(id: DefaultsKey(host: connection?.id, folder: window.draftDirectory,
                                  model: window.draftModel, connected: connection?.state == .connected)) {
                await readDefaults()
            }
    }

    /// Above the composer: nothing on a draft, and while a chat sent from here starts, its prompt
    /// and Starting Session, laid out as the chat will be, so moving to it moves nothing.
    @ViewBuilder private func content(_ starting: PendingStart?) -> some View {
        if let starting {
            TranscriptView(thread: starting.placeholder)
                // Its prompt is the window's copy until the chat exists: nothing to fork or restore.
                .environment(\.offersChatActions, false)
        } else {
            Color.clear
        }
    }

    private struct DefaultsKey: Equatable {
        let host: UUID?
        let folder: String?
        let model: String?
        let connected: Bool
    }

    private func readDefaults() async {
        guard let connection, connection.state == .connected else { return }
        // The last answer stays until this one's, so the menus don't blink.
        let defaults = await connection.sessionDefaults(cwd: window.draftDirectory, model: window.draftModel)
        guard !Task.isCancelled else { return }
        window.draftDefaults = defaults
    }

    private struct GitKey: Equatable {
        let folder: String?
        let connected: Bool
        let active: Bool
    }

    private func readGit() async {
        guard readsGit, appearsActive else { return }
        guard let folder = window.draftDirectory, let connection, connection.state == .connected else {
            git = nil
            return
        }
        // The previous folder's chips stay until this one's answer, so they don't blink.
        let status = await connection.gitStatus(cwd: folder)
        guard !Task.isCancelled else { return }
        git = status.map { FolderGit(isRepository: $0.isRepo, branch: $0.branchName) }
    }

    /// Where the chat works, above the composer where a chat's status strip goes: one glass chip,
    /// "tether-app · main", opening a popover with the directory, the branch checked out there and
    /// whether to work in it or in a new worktree. One control rather than three, so nothing in
    /// the row moves as choices change.
    private func chips(_ connection: HostConnection) -> some View {
        WhereChip(window: window, connection: connection, git: git, chooseFolder: chooseFolder, choose: choose)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func workInTitle(_ worktree: Bool) -> String { worktree ? "New Worktree" : "This Directory" }
    static func workInSymbol(_ worktree: Bool) -> String { worktree ? "folder.badge.plus" : "folder" }

    private func choose(_ directory: String?) {
        window.draftDirectory = directory
        window.draftError = nil
    }

    private func useFirstProjectIfUnset() {
        guard window.draftDirectory == nil, window.app.appearance.newChatFolder == .recent else { return }
        window.draftDirectory = connection?.projects.first?.cwd
    }

    private func chooseFolder() {
        choosingFolder = true
    }

    private func start(_ connection: HostConnection, _ input: [UserInput]) async -> Bool {
        await window.startDraftChat(input)
    }
}

/// The chip and its popover: where a new chat works.
private struct WhereChip: View {
    @Bindable var window: WindowModel
    let connection: HostConnection
    let git: NewChatView.FolderGit?
    let chooseFolder: () -> Void
    let choose: (String?) -> Void
    @State private var isPresented = false

    private var folder: String? { window.draftDirectory }

    /// "tether-app · main", or the folder alone outside a repository.
    private var title: String {
        guard let folder else { return "Choose Directory" }
        let name = (folder as NSString).lastPathComponent
        return git?.branch.map { "\(name) · \($0)" } ?? name
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(title, systemImage: NewChatView.workInSymbol(window.draftWorktree))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help(folder ?? "Choose the directory Claude works in")
        .accessibilityLabel("Directory")
        .accessibilityValue([folder?.abbreviatingHome ?? "None", git?.branch.map { "branch \($0)" },
                             NewChatView.workInTitle(window.draftWorktree)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("newChat.folder")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            form.popoverSize(width: 340)
        }
    }

    private var form: some View {
        Form {
            Section("Directory") {
                Picker("Directory", selection: Binding(get: { folder }, set: { choose($0) })) {
                    ForEach(connection.projects.prefix(15), id: \.cwd) { p in
                        Text(p.cwd.abbreviatingHome).tag(Optional(p.cwd))
                    }
                    if let folder, !connection.projects.contains(where: { $0.cwd == folder }) {
                        Text(folder.abbreviatingHome).tag(Optional(folder))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .lineLimit(1)
                .truncationMode(.middle)
                Button("Choose Directory…") {
                    isPresented = false
                    chooseFolder()
                }
            }
            if let branch = git?.branch {
                Section {
                    LabeledContent("Branch") {
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    .accessibilityIdentifier("newChat.branch")
                }
            }
            Section("Work In") {
                Picker("Work In", selection: $window.draftWorktree) {
                    Text(NewChatView.workInTitle(false)).tag(false)
                    Text(NewChatView.workInTitle(true)).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // A folder outside a repository has nothing to make a worktree of.
                .disabled(git?.isRepository == false)
                .accessibilityIdentifier("newChat.workIn")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#if DEBUG
/// A window on New Chat, its folder the sample host's most recent project.
@MainActor
private func newChatPreview(worktree: Bool = false, folder: String? = nil,
                            git: NewChatView.FolderGit?) -> some View {
    let window = WindowModel.sample()
    window.draftWorktree = worktree
    if let folder { window.draftDirectory = folder }
    return NavigationStack {
        NewChatView(window: window, previewGit: git)
    }
    .frame(width: 900, height: 500)
}

#Preview("NewChatView (repository)") {
    newChatPreview(git: .init(isRepository: true, branch: "main"))
}

#Preview("NewChatView (not a repository)") {
    newChatPreview(folder: NSHomeDirectory() + "/Downloads", git: .init(isRepository: false))
}

#Preview("NewChatView (new worktree)") {
    newChatPreview(worktree: true, git: .init(isRepository: true, branch: "feature/new-chat-chips"))
}

/// Sent, before the host has started the session: the prompt, and Starting Session under it.
#Preview("Starting session") {
    let window = WindowModel.sample()
    window.starting = .sample()
    return NavigationStack {
        NewChatView(window: window, previewGit: .init(isRepository: true, branch: "main"))
    }
    .frame(width: 900, height: 500)
}

#Preview("NewChatView (not connected)") {
    NavigationStack {
        NewChatView(window: .sample(.sample(connections: [.sampleFailed()])))
    }
    .frame(width: 900, height: 700)
}

#endif
