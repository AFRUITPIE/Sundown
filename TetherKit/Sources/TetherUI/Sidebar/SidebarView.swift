import AppKit
import SwiftUI
import TetherKit

/// The chats of the one host the window is showing: grouped, searchable, and with a single
/// context menu for the whole list.
struct SidebarView: View {
    @Bindable var app: AppModel
    @State private var search: String
    @State private var renaming: ThreadModel?
    @State private var renameTitle = ""

    /// `search` is a parameter only so a preview can show the no-results state.
    init(app: AppModel, search: String = "") {
        self.app = app
        _search = State(initialValue: search)
    }

    var body: some View {
        // Once per body: the list and its empty state both need it, and it sorts every chat.
        let sections = resolvedSections
        List(selection: $app.threadID) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        ChatRow(thread: row.thread, grouping: app.sidebarGrouping)
                            .tag(row.id)
                    }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search Chats")
        // One menu for the list: the row's when a row was hit, the list's own when the empty area was.
        .contextMenu(forSelectionType: String.self) { menu(for: $0) }
        .overlay { emptyState(isEmpty: sections.isEmpty) }
        // On the List, not on a Section: a Section is not where SwiftUI looks for a presentation.
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameTitle)
            Button("Rename") {
                if let thread = renaming, let connection = app.connection, !renameTitle.isEmpty {
                    Task { await connection.rename(thread, renameTitle) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .safeAreaBar(edge: .top) { hostSelector }
    }

    // MARK: rows

    /// The chats of the current host, as the little grouping needs of them. Reading a thread's
    /// title, folder and timestamp here is deliberate: none of them changes while a turn streams.
    private var sections: [SidebarSection] {
        sidebarSections(
            chats: threads.map { SidebarChat(id: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: $0.summary?.updatedAt) },
            grouping: app.sidebarGrouping,
            search: search)
    }

    private var threads: [ThreadModel] { app.connection?.chats ?? [] }

    private var threadsByID: [String: ThreadModel] {
        Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private struct ResolvedRow: Identifiable {
        let id: String
        let thread: ThreadModel
    }

    private struct ResolvedSection: Identifiable {
        let id: String
        let title: String
        let help: String?
        let rows: [ResolvedRow]
    }

    /// Chats paired with their live models before the `ForEach`, so neither a row nor a section
    /// in the list can build to nothing: the sidebar's outline list traps on an empty item.
    private var resolvedSections: [ResolvedSection] {
        let byID = threadsByID
        return sections.compactMap { section in
            let rows = section.chats.compactMap { chat in
                byID[chat.id].map { ResolvedRow(id: chat.id, thread: $0) }
            }
            guard !rows.isEmpty else { return nil }
            return ResolvedSection(id: section.id, title: section.title, help: section.help, rows: rows)
        }
    }

    @ViewBuilder private func header(_ section: ResolvedSection) -> some View {
        if let help = section.help {
            Text(section.title).help(help)
        } else {
            Text(section.title)
        }
    }

    // MARK: host selector

    /// Only worth a control when there is something to switch between; the one host's name is
    /// already the window's, and Settings is where hosts are added.
    @ViewBuilder private var hostSelector: some View {
        if app.hosts.count > 1 {
            Picker("Host", selection: $app.hostID) {
                ForEach(app.hosts) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Leading, with the pop-up's own bezel inset taken off, so its title lines up with
            // the row titles under it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .contextMenu { hostActions }
        }
    }

    @ViewBuilder private var hostActions: some View {
        if let connection = app.connection {
            Button("Reconnect") { Task { await connection.reconnect() } }
            if let info = connection.serverInfo {
                Divider()
                Text("Claude Code \(info.claude.version)")
            }
        }
    }

    // MARK: menus

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        if let id = ids.first, let thread = threadsByID[id], let connection = app.connection {
            Button("Rename…") {
                renameTitle = thread.title
                renaming = thread
            }
            Button("Duplicate") {
                Task { if let fork = await connection.fork(thread) { app.open(threadID: fork.id) } }
            }
            if let cwd = thread.cwd, connection.host.isLocal {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await connection.delete(thread) } }
        } else {
            Picker("Group By", selection: $app.sidebarGrouping) {
                ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Divider()
            hostActions
        }
    }

    // MARK: states

    /// Shown only when there is no list to show: a reconnect that still has its chats keeps them
    /// on screen rather than covering them with a progress message.
    @ViewBuilder private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty, let connection = app.connection {
            switch connection.state {
            case .connecting(let message):
                ContentUnavailableView { ProgressView() } description: { Text(message) }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await connection.reconnect() } }
                }
            case .disconnected:
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "bolt.horizontal.circle")
                } actions: {
                    Button("Connect") { Task { await connection.connect() } }
                }
            case .connected:
                if search.isEmpty {
                    ContentUnavailableView("No Chats", systemImage: "bubble.left")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }
}

#if DEBUG
/// The sidebar as the split view hosts it: same column width as RootView, so truncation and
/// alignment here are the ones the app has.
private func sidebarPreview(_ app: AppModel, search: String = "") -> some View {
    NavigationSplitView {
        SidebarView(app: app, search: search)
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
    } detail: {
        Text("Detail").foregroundStyle(.secondary)
    }
    .frame(width: 900, height: 640)
}

#Preview("Sidebar (by date)") {
    sidebarPreview(.sample())
}

#Preview("Sidebar (by directory)") {
    let app = AppModel.sample()
    app.sidebarGrouping = .directory
    return sidebarPreview(app)
}

#Preview("Sidebar (two hosts)") {
    sidebarPreview(.sample(connections: [.sample(), .sampleConnecting()]))
}

#Preview("Sidebar (host failed)") {
    let failed = HostConnection.sampleFailed()
    let app = AppModel.sample(connections: [.sample(), failed])
    app.hostID = failed.id
    return sidebarPreview(app)
}

#Preview("Sidebar (host connecting)") {
    let connecting = HostConnection.sampleConnecting()
    let app = AppModel.sample(connections: [.sample(), connecting])
    app.hostID = connecting.id
    return sidebarPreview(app)
}

#Preview("Sidebar (no chats)") {
    sidebarPreview(.sample(connections: [.sampleEmpty()]))
}

#Preview("Sidebar (host disconnected)") {
    sidebarPreview(.sample(connections: [.sampleDisconnected()]))
}

#Preview("Sidebar (no search results)") {
    sidebarPreview(.sample(), search: "kubernetes")
}
#endif
