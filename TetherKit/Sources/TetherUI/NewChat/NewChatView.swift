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
        Color.clear
            .inspectorCardOverlay()
            .safeAreaBar(edge: .bottom) {
                if let connection {
                    VStack(alignment: .leading, spacing: 10) {
                        if connection.state == .connected { chips(connection) }
                        Group {
                            if let error = window.draftError {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            GlassEffectContainer(spacing: 10) {
                                Composer(connection: connection, cwd: window.draftDirectory,
                                         draftKey: "new-chat:\(window.hostID)",
                                         placeholder: window.draftDirectory == nil ? "Choose a directory, then ask Claude…" : "Ask Claude…",
                                         submit: { input in await start(connection, input) },
                                         // Dropped on the field too, a directory is where the chat starts.
                                         takesDirectory: connection.host.isLocal ? { choose($0) } : nil)
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
            .dropDestination(for: URL.self, isEnabled: connection?.host.isLocal == true) { urls, _ in
                if let folder = urls.first(where: \.hasDirectoryPath) { choose(folder.path) }
            }
            .onAppear { useFirstProjectIfUnset() }
            .onChange(of: connection?.projects.first?.cwd) { useFirstProjectIfUnset() }
            // Read again when the window comes back to the front, since the branch may have been
            // switched in a terminal meanwhile.
            .task(id: GitKey(folder: window.draftDirectory, connected: connection?.state == .connected, active: appearsActive)) {
                await readGit()
            }
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

    /// Where the chat works, above the composer where a chat's status strip goes: the folder, the
    /// branch checked out there, and whether to work in it or in a new worktree. Plain borderless
    /// menus, since the composer beneath them is the glass. Work In is last because its label
    /// changes width with the choice (a menu button's label can't reserve it), and nothing
    /// should move when it does.
    private func chips(_ connection: HostConnection) -> some View {
        HStack(spacing: 16) {
            folderMenu(connection)
            if let branch = git?.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    // Spaced like the menus' labels beside it.
                    .labelIconToTitleSpacing(4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help("Branch")
                    .accessibilityLabel("Branch \(branch)")
                    .accessibilityIdentifier("newChat.branch")
            }
            workInMenu
        }
        .labelStyle(.titleAndIcon)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Recent folders, then Choose Folder… for any other.
    private func folderMenu(_ connection: HostConnection) -> some View {
        let folder = window.draftDirectory
        return Menu {
            Picker("Directory", selection: Binding(get: { window.draftDirectory }, set: { choose($0) })) {
                ForEach(connection.projects.prefix(15), id: \.cwd) { p in
                    Text(p.cwd.abbreviatingHome).tag(Optional(p.cwd))
                }
                if let folder, !connection.projects.contains(where: { $0.cwd == folder }) {
                    Text(folder.abbreviatingHome).tag(Optional(folder))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Choose Directory…", action: chooseFolder)
        } label: {
            // The whole path, since the window's subtitle already names the folder. No symbol:
            // Work In's folder beside it would read as a second one.
            Text(folder?.abbreviatingHome ?? "Choose Directory")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // Gives way before the others: a long path truncates in its middle instead.
        .layoutPriority(-1)
        .help(folder ?? "Choose the directory Claude works in")
        .accessibilityLabel("Directory")
        .accessibilityValue(folder ?? "None")
        .accessibilityIdentifier("newChat.folder")
    }

    /// The folder itself, or a new git worktree of its repository on a branch of its own, so
    /// parallel chats in one repository don't share a checkout. Settings ▸ General sets which
    /// a new chat starts with.
    private var workInMenu: some View {
        let worktree = window.draftWorktree
        return Menu {
            Picker("Work In", selection: $window.draftWorktree) {
                Label(Self.workInTitle(false), systemImage: Self.workInSymbol(false)).tag(false)
                Label(Self.workInTitle(true), systemImage: Self.workInSymbol(true)).tag(true)
                    // A folder outside a repository has nothing to make a worktree of.
                    .selectionDisabled(git?.isRepository == false)
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.workInTitle(worktree), systemImage: Self.workInSymbol(worktree))
        }
        .help(worktree ? "Work in a new git worktree of this directory’s repository" : "Work in this directory")
        .accessibilityLabel("Work In")
        .accessibilityValue(Self.workInTitle(worktree))
        .accessibilityIdentifier("newChat.workIn")
    }

    private static func workInTitle(_ worktree: Bool) -> String { worktree ? "New Worktree" : "This Directory" }
    private static func workInSymbol(_ worktree: Bool) -> String { worktree ? "folder.badge.plus" : "folder" }

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

    private func start(_ connection: HostConnection, _ input: [UserInput]) async {
        await window.startDraftChat(input)
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

#Preview("NewChatView (not connected)") {
    NavigationStack {
        NewChatView(window: .sample(.sample(connections: [.sampleFailed()])))
    }
    .frame(width: 900, height: 700)
}

#endif
