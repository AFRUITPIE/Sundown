import AppKit
import SwiftUI
import TetherKit

/// The chats of the one host the window is showing: grouped, searchable, and with a single
/// context menu for the whole list.
struct SidebarView: View {
    @Bindable var window: WindowModel
    @State private var search: String
    @Environment(\.openWindow) private var openWindow

    /// `search` is a parameter only so a preview can show the no-results state.
    init(window: WindowModel, search: String = "") {
        self.window = window
        _search = State(initialValue: search)
    }

    private var app: AppModel { window.app }

    var body: some View {
        // Once per body: the list and its empty state both need it, and it sorts every chat.
        let sections = resolvedSections
        List(selection: $window.threadID) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        ChatRow(thread: row.thread, grouping: app.sidebarGrouping)
                            .tag(row.id)
                            // The full title, for one the column truncates.
                            .help(row.thread.title)
                    }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search Chats")
        // One menu for the list: the row's when a row was hit, the list's own when the empty area was.
        .contextMenu(forSelectionType: String.self) { menu(for: $0) } primaryAction: { ids in
            // Double-click, as Mail opens a message: in a window of its own.
            guard let id = ids.first else { return }
            openWindow(value: WindowTarget(hostID: window.hostID, threadID: id))
        }
        .overlay { emptyState(isEmpty: sections.isEmpty) }
        // A folder dragged from Finder onto the list starts a new chat in it.
        .dropDestination(for: URL.self) { urls, _ in
            guard window.connection?.host.isLocal == true, let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            window.newChat()
            window.draftDirectory = folder.path
            return true
        }
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

    private var threads: [ThreadModel] {
        let filter = app.sidebarFilter
        return (window.connection?.chats ?? []).filter { filter.includes($0) || $0 === window.selectedThread }
    }

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

    @ViewBuilder private var hostActions: some View {
        if let connection = window.connection {
            ConnectButton(connection: connection)
            if let info = connection.serverInfo {
                Divider()
                Text("Claude Code \(info.claude.version)")
            }
        }
    }

    // MARK: menus

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        if let id = ids.first, let thread = threadsByID[id] {
            ChatActionItems(window: window, thread: thread, hidesUnavailable: true)
        } else {
            Picker("Group By", selection: Bindable(app).sidebarGrouping) {
                ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Show", selection: Bindable(app).sidebarFilter) {
                ForEach(SidebarFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            hostActions
        }
    }

    // MARK: states

    /// Shown only when there is no list to show: a reconnect that still has its chats keeps them
    /// on screen rather than covering them with a progress message.
    @ViewBuilder private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty, let connection = window.connection {
            switch connection.state {
            case .connecting(let message):
                ContentUnavailableView { ProgressView() } description: { Text(message) }
            case .failed, .disconnected:
                NotConnectedView(connection: connection)
            case .connected:
                if search.isEmpty, app.sidebarFilter != .all {
                    ContentUnavailableView {
                        Label("No \(app.sidebarFilter.label) Chats", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("Show All Chats") { app.sidebarFilter = .all }
                    }
                } else if search.isEmpty {
                    ContentUnavailableView("No Chats", systemImage: "bubble.left")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }
}

/// A host that isn't connected, and how to connect it: the sidebar's empty state, and New Chat's.
/// Empty while the host is connected or connecting.
struct NotConnectedView: View {
    let connection: HostConnection

    var body: some View {
        switch connection.state {
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
        case .connecting, .connected:
            EmptyView()
        }
    }
}

#if DEBUG
/// The sidebar as the split view hosts it: same column width as RootView, so truncation and
/// alignment here are the ones the app has.
@MainActor
private func sidebarPreview(_ app: AppModel, host: UUID? = nil, search: String = "") -> some View {
    let window = WindowModel.sample(app)
    if let host { window.hostID = host }
    return NavigationSplitView {
        SidebarView(window: window, search: search)
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
    return sidebarPreview(.sample(connections: [.sample(), failed]), host: failed.id)
}

#Preview("Sidebar (host connecting)") {
    let connecting = HostConnection.sampleConnecting()
    return sidebarPreview(.sample(connections: [.sample(), connecting]), host: connecting.id)
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
