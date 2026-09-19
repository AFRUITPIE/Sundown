import SwiftUI
import TetherKit
import TetherProtocol

public struct RootView: View {
    @Bindable var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
        }
        .task { app.connectAll() }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .thread(let h, let id):
            if let c = app.connection(h) {
                ThreadView(thread: c.thread(id), connection: c).id(id)
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
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { app.newChat() }
                    .help("New Chat (⌘N)")
            }
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
    let app: AppModel
    @State var hostId: UUID
    @State private var directory: String?
    @State private var model: String?
    @State private var effort: EffortLevel?
    @State private var mode: PermissionMode = .default
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
                    VStack(spacing: 10) {
                        HStack {
                            ModelPicker(selection: $model, models: connection.models)
                            EffortPicker(selection: $effort, levels: connection.models.first { $0.value == model }?.supportedEffortLevels ?? EffortLevel.allCases)
                            PermissionModePicker(selection: $mode)
                        }
                        .fixedSize()
                        Composer(connection: connection, cwd: directory, placeholder: directory == nil ? "Choose a folder, then ask Claude…" : "Ask Claude…") { input in
                            await start(connection, input)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .frame(maxWidth: 940)
            }
        }
        .fileImporter(isPresented: $choosingLocalFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { directory = url.path }
        }
        .sheet(isPresented: $choosingRemoteFolder) {
            if let connection { RemoteFolderPicker(connection: connection) { directory = $0 } }
        }
        .onAppear {
            model = app.defaultModel
            effort = app.defaultEffort.map { EffortLevel(rawValue: $0) }
            mode = PermissionMode(rawValue: app.defaultPermissionMode)
            directory = directory ?? connection?.projects.first?.cwd
        }
        .onChange(of: hostId) { directory = connection?.projects.first?.cwd }
    }

    private func chooseFolder() {
        if connection?.host.isLocal == true { choosingLocalFolder = true } else { choosingRemoteFolder = true }
    }

    private func start(_ connection: HostConnection, _ input: [UserInput]) async {
        guard let cwd = directory else { error = "Choose a folder first."; return }
        do {
            let t = try await connection.startThread(cwd: cwd, input: input, options: .init(model: model, effort: effort, permissionMode: mode))
            app.selection = .thread(host: connection.id, id: t.id)
        } catch {
            self.error = error.localizedDescription
        }
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
