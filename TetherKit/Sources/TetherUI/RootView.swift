import SwiftUI
import TetherKit
import TetherProtocol

public struct RootView: View {
    @Bindable var app: AppModel
    /// Seeded rather than fixed so a preview can render the window with the sidebar collapsed —
    /// which is the only way to see that New Chat goes away with it.
    @State private var columns: NavigationSplitViewVisibility

    public init(app: AppModel, columnVisibility: NavigationSplitViewVisibility = .automatic) {
        self.app = app
        self._columns = State(initialValue: columnVisibility)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
        }
        // Attached to the split view itself (not the detail column) so the inspector spans the
        // full window height and slides in under a toolbar that never moves, like Xcode's right
        // sidebar — and one stable toolbar here means New Chat/Inspector never disappear when
        // switching between the sidebar, a chat and the New Chat screen.
        .inspector(isPresented: $app.showInspector) {
            inspector
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar { AppToolbar(app: app) }
        // Without this the titlebar paints its own background across the top of every column,
        // so the inspector looks like it starts below a header strip instead of running the
        // full height of the window the way the sidebar does.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environment(\.readingWidth, app.transcriptWidth.points)
        .task { app.connectAll() }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .thread(let host, let id):
            if let thread = app.selectedThread, let c = app.selectedConnection {
                ThreadView(thread: thread, connection: c).id(id)
            } else {
                // The host this chat belongs to is gone (removed in Settings while it was
                // selected); an empty detail column would just look broken.
                ContentUnavailableView {
                    Label("Host Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The host for this chat is no longer configured.")
                } actions: {
                    Button("New Chat") { app.newChat() }
                }
                .id(host)
            }
        case .newChat(let h):
            NewChatView(app: app, hostId: h).id(h)
        case nil:
            ContentUnavailableView {
                Label("No Chat Selected", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Claude Code on this Mac or any host you can reach over SSH.")
            } actions: {
                Button("New Chat") { app.newChat() }
            }
        }
    }

    /// The inspector needs a selected thread + its connection; otherwise there's nothing to show.
    @ViewBuilder private var inspector: some View {
        if let thread = app.selectedThread, let connection = app.selectedConnection {
            ThreadInspector(thread: thread, connection: connection)
        } else {
            ContentUnavailableView {
                Label("No Thread Selected", systemImage: "sidebar.trailing")
            }
        }
    }
}

/// What is left in the window toolbar once each control sits with the thing it acts on: the
/// inspector toggle, beside the system's own sidebar toggle and the window title. New Chat moved
/// into the sidebar it creates rows in, and the session controls into the chat they configure.
/// (HIG, Toolbars: "Choose items deliberately to avoid overcrowding.")
struct AppToolbar: ToolbarContent {
    @Bindable var app: AppModel

    var body: some ToolbarContent {
        ToolbarItem {
            // The chat's settings, in the toolbar the way SF Symbols puts its family and weight
            // pop-ups there: text and a chevron, no icon, showing the current value.
            // Each sizes to its own content: left to stretch, the last one absorbs the slack and
            // truncates its label away to nothing.
            HStack(spacing: 8) { sessionControls }
                .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            // A plain Button (not a Toggle) so the icon never lights up while open — Xcode's own
            // right-sidebar button behaves the same way.
            Button("Inspector", systemImage: "sidebar.trailing") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(app.showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

}

extension AppToolbar {
    /// Model, effort and permissions for whatever is selected: a live chat's own state, or the
    /// New Chat screen's draft.
    @ViewBuilder var sessionControls: some View {
        switch app.selection {
        case .thread:
            if let thread = app.selectedThread, let c = app.selectedConnection {
                ThreadControls(thread: thread, connection: c)
            }
        case .newChat(let h):
            if let c = app.connection(h) {
                NewChatControls(app: app, connection: c)
            }
        case nil:
            EmptyView()
        }
    }
}

/// Chats per host, most recent first. Two levels only: host section → chat.
struct SidebarView: View {
    @Bindable var app: AppModel
    @State private var search = ""

    var body: some View {
        List(selection: $app.selection) {
            ForEach(app.hosts) { host in
                if let c = app.connection(host.id) {
                    HostSection(app: app, connection: c, search: search)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        // Attached to the sidebar's own content, so it belongs to that column and goes away with
        // it when the sidebar collapses, instead of floating in the window-wide toolbar.
        // In the sidebar's own content, not its toolbar: a `.toolbar` declared on a column is
        // still hoisted into the window-wide titlebar, so it stayed put when the sidebar
        // collapsed. A bottom bar belongs to the column and goes away with it — the same place
        // Reminders puts New List.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    app.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .help("New Chat (⌘N)")
            }
            .background(.bar)
        }
    }
}

struct HostSection: View {
    let app: AppModel
    let connection: HostConnection
    let search: String
    @State private var renaming: ThreadModel?
    @State private var newTitle = ""

    var body: some View {
        Section {
            switch connection.state {
            case .connected:
                // A connected host with nothing to list used to render as a bare header with a
                // blank space under it, which reads as still loading.
                if filtered.isEmpty {
                    Label(search.isEmpty ? "No chats yet" : "No matches",
                          systemImage: search.isEmpty ? "bubble.left" : "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { t in
                    ChatRow(thread: t)
                        .badge(t.pending.count)
                        .tag(SidebarSelection.thread(host: connection.id, id: t.id))
                        .contextMenu { menu(for: t) }
                }
            case .connecting(let m):
                Label(m, systemImage: "hourglass").foregroundStyle(.secondary)
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(3)
                Button("Try Again") { Task { await connection.reconnect() } }
            case .disconnected:
                Button("Connect") { Task { await connection.connect() } }
            }
        } header: {
            HStack {
                Text(connection.host.name)
                if let p = connection.account?.apiProvider, p != "firstParty" {
                    Text(p.capitalized).foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
                Button("Reconnect") { Task { await connection.reconnect() } }
                if let s = connection.serverInfo {
                    Divider()
                    Text("Claude Code \(s.claude.version)")
                }
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let t = renaming, !newTitle.isEmpty { Task { await connection.rename(t, newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var filtered: [ThreadModel] {
        search.isEmpty ? connection.chats : connection.chats.filter {
            $0.title.localizedCaseInsensitiveContains(search) || ($0.cwd ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    @ViewBuilder private func menu(for t: ThreadModel) -> some View {
        Button("Rename…") {
            newTitle = t.title
            renaming = t
        }
        Button("Duplicate") {
            Task { if let f = await connection.fork(t) { app.selection = .thread(host: connection.id, id: f.id) } }
        }
        if let cwd = t.cwd, connection.host.isLocal {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await connection.delete(t) } }
    }
}

struct ChatRow: View {
    let thread: ThreadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if thread.isRunning {
                    Image(systemName: thread.status == .requiresAction ? "exclamationmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(thread.status == .requiresAction ? .orange : .accentColor)
                        .symbolEffect(.rotate, isActive: thread.status == .running)
                }
                Text(thread.title).lineLimit(1)
            }
            HStack(spacing: 4) {
                if let cwd = thread.cwd { Text(cwd.lastPathComponent) }
                if let t = thread.summary?.updatedAt {
                    Text("·")
                    Text(Format.relative(msSinceEpoch: t))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Compose a new chat: choose the host and working directory, then send the first message.
struct NewChatView: View {
    @Bindable var app: AppModel
    @Environment(\.readingWidth) private var readingWidth
    @State var hostId: UUID
    @State private var directory: String?
    @State private var error: String?
    @State private var choosingLocalFolder = false
    @State private var choosingRemoteFolder = false

    private var connection: HostConnection? { app.connection(hostId) }

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: $hostId) {
                    ForEach(app.hosts) { Text($0.name).tag($0.id) }
                }
                Picker("Folder", selection: Binding(get: { directory }, set: { new in
                    if new == "__choose__" { chooseFolder() } else { directory = new }
                })) {
                    Text("Choose a folder").tag(String?.none)
                    ForEach(connection?.projects.prefix(15) ?? [], id: \.cwd) { p in
                        Text(p.cwd.abbreviatingHome).tag(Optional(p.cwd))
                    }
                    if let d = directory, !(connection?.projects.contains { $0.cwd == d } ?? false) {
                        Text(d.abbreviatingHome).tag(Optional(d))
                    }
                    Divider()
                    Text("Choose…").tag(Optional("__choose__"))
                }
            } footer: {
                if let e = error { Text(e).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("New Chat")
        .safeAreaBar(edge: .bottom) {
            if let connection {
                GlassEffectContainer(spacing: 10) {
                    Composer(connection: connection, cwd: directory, placeholder: directory == nil ? "Choose a folder, then ask Claude…" : "Ask Claude…", submit: { input in
                        await start(connection, input)
                    })
                }
                .padding(.horizontal, Layout.gutter)
                .padding(.bottom, 14)
                .frame(maxWidth: readingWidth)
            }
        }
        .fileImporter(isPresented: $choosingLocalFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { directory = url.path }
        }
        .sheet(isPresented: $choosingRemoteFolder) {
            if let connection { RemoteFolderPicker(connection: connection) { directory = $0 } }
        }
        // The host is usually still connecting when this appears, so the project list arrives
        // after the fact — without the second hook the folder picker stays empty for good.
        .onAppear { useFirstProjectIfUnset() }
        .onChange(of: connection?.projects.first?.cwd) { useFirstProjectIfUnset() }
        .onChange(of: hostId) {
            directory = nil
            useFirstProjectIfUnset()
        }
    }

    private func useFirstProjectIfUnset() {
        guard directory == nil else { return }
        directory = connection?.projects.first?.cwd
    }

    private func chooseFolder() {
        if connection?.host.isLocal == true { choosingLocalFolder = true } else { choosingRemoteFolder = true }
    }

    private func start(_ connection: HostConnection, _ input: [UserInput]) async {
        guard let cwd = directory else { error = "Choose a folder first."; return }
        do {
            let t = try await connection.startThread(cwd: cwd, input: input,
                                                       options: .init(model: app.draftModel, effort: app.draftEffort, permissionMode: app.draftPermissionMode))
            app.selection = .thread(host: connection.id, id: t.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Model, effort and permission menus for the New Chat screen (shown in the window toolbar),
/// bound to the app's draft session-control state until the thread starts.
struct NewChatControls: View {
    @Bindable var app: AppModel
    let connection: HostConnection

    private var currentModelInfo: ModelInfo? {
        connection.models.first { $0.value == app.draftModel || $0.resolvedModel == app.draftModel } ?? connection.models.first
    }

    var body: some View {
        ModelPicker(selection: $app.draftModel, models: connection.models)
        EffortPicker(selection: $app.draftEffort, levels: currentModelInfo?.supportedEffortLevels ?? EffortLevel.allCases)
        PermissionModePicker(selection: $app.draftPermissionMode)
    }
}

/// Browse directories on a remote host via fs/list.
struct RemoteFolderPicker: View {
    let connection: HostConnection
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = "~"
    @State private var entries: [FsListResult.Entry] = []
    @State private var error: String?
    @State private var selection: String?

    var body: some View {
        NavigationStack {
            List(entries.filter(\.isDirectory), id: \.path, selection: $selection) { e in
                Label(e.name, systemImage: "folder")
                    .onTapGesture(count: 2) { path = e.path; Task { await load() } }
            }
            .navigationTitle(path.abbreviatingHome)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Enclosing Folder", systemImage: "chevron.up") {
                        path = (path as NSString).deletingLastPathComponent
                        Task { await load() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") { done(selection ?? path); dismiss() }
                }
            }
            .overlay { if let error { ContentUnavailableView(error, systemImage: "exclamationmark.triangle") } }
        }
        .frame(width: 520, height: 420)
        .task { await load() }
    }

    private func load() async {
        do {
            entries = try await connection.listDirectory(path)
            if let first = entries.first { path = (first.path as NSString).deletingLastPathComponent }
            selection = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#if DEBUG
// #Preview bodies are result-builder closures (no `if`/control flow), so the selection is set here.
@MainActor
private func rootPreviewApp() -> AppModel {
    let app = AppModel.sample()
    if let connection = app.connections.values.first, let chat = connection.chats.first {
        app.selection = .thread(host: connection.id, id: chat.id)
    }
    return app
}

#Preview("RootView") {
    RootView(app: rootPreviewApp())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (no selection)") {
    RootView(app: .sample())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (inspector open)") {
    let app = rootPreviewApp()
    app.showInspector = true
    return RootView(app: app)
        .frame(width: 1100, height: 760)
}

#Preview("RootView (new chat)") {
    let app = AppModel.sample()
    app.newChat()
    return RootView(app: app)
        .frame(width: 1100, height: 760)
}

#Preview("RootView (wide transcript)") {
    let app = rootPreviewApp()
    app.transcriptWidth = .wide
    return RootView(app: app)
        .frame(width: 1400, height: 760)
}

#Preview("RootView (sidebar collapsed)") {
    RootView(app: rootPreviewApp(), columnVisibility: .detailOnly)
        .frame(width: 1100, height: 760)
}

#Preview("SidebarView") {
    let app = AppModel.sample(connections: [.sample(), .sampleFailed(), .sampleConnecting()])
    NavigationSplitView {
        SidebarView(app: app)
    } detail: {
        Text("Detail")
    }
    .frame(width: 320, height: 640)
}

#Preview("HostSection") {
    let connection = HostConnection.sample()
    List {
        HostSection(app: .sample(connections: [connection]), connection: connection, search: "")
    }
    .listStyle(.sidebar)
    .frame(width: 300, height: 420)
}

#Preview("ChatRow") {
    List {
        ChatRow(thread: .sampleIdleChat())
        ChatRow(thread: .sampleRunningTurn())
        ChatRow(thread: .samplePendingPermission())
        ChatRow(thread: .sampleErrorTurn())
    }
    .frame(width: 300, height: 240)
}

#Preview("NewChatView") {
    let connection = HostConnection.sample()
    NavigationStack {
        NewChatView(app: .sample(connections: [connection]), hostId: connection.id)
    }
    .frame(width: 900, height: 700)
}

#Preview("RemoteFolderPicker") {
    // No client (unlike `.sample()`): `listDirectory` fails fast with "Not connected", so the
    // preview shows a clear empty state instead of an fs/list call that hangs forever.
    let connection = HostConnection(host: .local)
    connection.previewSeed(state: .connected)
    return RemoteFolderPicker(connection: connection) { _ in }
}

#endif
