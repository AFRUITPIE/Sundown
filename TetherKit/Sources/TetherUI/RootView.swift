import SwiftUI
import TetherKit
import TetherProtocol

public struct RootView: View {
    @Bindable var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    // No columnVisibility binding: writing it on every sidebar toggle rebuilt the toolbar mid-animation.
    public var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
        }
        .toolbar { AppToolbar(app: app) }
        .environment(\.readingWidth, app.transcriptWidth.points)
        .task { app.connectAll() }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .thread(let host, _):
            if let thread = app.selectedThread, let c = app.selectedConnection {
                ChatDetail(app: app, thread: thread, connection: c)
            } else {
                // The chat's host was removed while it was selected.
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
            // Fallback if the List transiently clears its selection.
            NewChatView(app: app, hostId: HostConfig.local.id)
        }
    }

}

/// One stable window toolbar: New Chat beside the sidebar toggle, the inspector toggle at the trailing edge.
struct AppToolbar: ToolbarContent {
    @Bindable var app: AppModel

    var body: some ToolbarContent {
        // Declared by the window: an item declared on a column is removed when it collapses, which relayouts every other item.
        ToolbarItem(placement: .navigation) {
            Button {
                app.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel("New Chat")
            .help("New Chat (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            sessionControls
            InspectorToggle(app: app)
        }
    }
}

extension AppToolbar {
    /// Session controls for the selected chat, or the New Chat draft.
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

/// A chat and its inspector. Separate from `RootView` so reading `showInspector` invalidates only
/// this view, not the window toolbar. Hanging the inspector here also keeps it off New Chat.
struct ChatDetail: View {
    @Bindable var app: AppModel
    let thread: ThreadModel
    let connection: HostConnection
    @State private var inspectedTaskID: String?

    var body: some View {
        ThreadView(thread: thread, connection: connection)
            .environment(\.inspectSubagent, InspectSubagentAction { toolUseId in
                inspectedTaskID = toolUseId
                app.showInspector = true
            })
            .inspector(isPresented: $app.showInspector) {
                ThreadInspector(thread: thread, connection: connection, selectedTaskID: $inspectedTaskID)
                    .environment(\.inspectSubagent, InspectSubagentAction { toolUseId in
                        inspectedTaskID = toolUseId
                    })
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
}

/// Its own view so reading `showInspector` invalidates only this button, not the whole toolbar.
struct InspectorToggle: View {
    @Bindable var app: AppModel

    var body: some View {
        if app.isThreadSelected {
            Button {
                app.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel("Inspector")
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(app.showInspector ? "Hide Inspector" : "Show Inspector")
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
        .searchable(text: $search, placement: .sidebar, prompt: "Search Chats")

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
                // Otherwise an empty host reads as still loading.
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
    /// From the selection, which the toolbar's session controls also read.
    let hostId: UUID
    @State private var directory: String?
    @State private var error: String?
    @State private var choosingLocalFolder = false
    @State private var choosingRemoteFolder = false

    private var connection: HostConnection? { app.connection(hostId) }

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: Binding(get: { hostId },
                                                   set: { app.selection = .newChat(host: $0) })) {
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
        // Projects usually arrive after this appears.
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

/// Session controls for the New Chat screen, bound to the app's draft.
struct NewChatControls: View {
    @Bindable var app: AppModel
    let connection: HostConnection

    private var currentModelInfo: ModelInfo? {
        let value = connection.models.concreteValue(for: app.draftModel ?? app.defaultModel)
        return connection.models.concrete.first { $0.value == value } ?? connection.models.concrete.first
    }

    var body: some View {
        // Also resolved here: the catalog usually lands after `newChat()` seeded the draft.
        ModelPicker(selection: Binding(get: { connection.models.concreteValue(for: app.draftModel ?? app.defaultModel) },
                                       set: { app.draftModel = $0 }),
                    models: connection.models)
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

#Preview("RootView (default new chat)") {
    RootView(app: .sample())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (inspector open)") {
    let app = rootPreviewApp()
    app.showInspector = true
    return RootView(app: app)
        .frame(width: 1100, height: 760)
}

#Preview("RootView (wide transcript)") {
    let app = rootPreviewApp()
    app.transcriptWidth = .wide
    return RootView(app: app)
        .frame(width: 1400, height: 760)
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
    // No client, so `listDirectory` fails fast and the preview shows the empty state.
    let connection = HostConnection(host: .local)
    connection.previewSeed(state: .connected)
    return RemoteFolderPicker(connection: connection) { _ in }
}

#endif
