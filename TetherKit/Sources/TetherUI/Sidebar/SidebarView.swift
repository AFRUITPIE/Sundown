import SwiftUI
import TetherKit

/// The chats of the one host the window is showing: grouped, searchable, and with a single
/// context menu for the whole list.
struct SidebarView: View {
    @Bindable var window: WindowModel
    @State private var search: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearance) private var appearance

    /// `search` is a parameter only so a preview can show the no-results state.
    init(window: WindowModel, search: String = "") {
        self.window = window
        _search = State(initialValue: search)
    }

    private var app: AppModel { window.app }

    var body: some View {
        // Once per body: the list, its menus and its empty state all need them, and grouping sorts
        // every chat.
        let threads = window.sidebarThreads
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sections = resolve(window.sidebarList(threads, style: appearance.sidebar, search: search), byID)
        List(selection: $window.threadID) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        // In a stack, so each element is one row SwiftUI can count without building it.
                        HStack { rowView(row, in: section) }
                            .tag(row.id)
                            // The full title, for one the column truncates.
                            .help(row.thread.title)
                            .swipeActions(edge: .trailing) { archiveSwipe(row.thread) }
                    }
                } header: {
                    header(section)
                }
                // New Chat Here, shown on hover over a directory's section, as the system shows a
                // section's actions.
                .sectionActions {
                    if let folder = section.folder {
                        Button("New Chat Here", systemImage: "square.and.pencil") { newChat(in: folder) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, isPresented: $window.searchingChats, placement: .sidebar, prompt: "Search Chats")
        // One menu for the list: the row's when a row was hit, the list's own when the empty area was.
        .contextMenu(forSelectionType: String.self) { menu(for: $0, in: byID) } primaryAction: { ids in
            // Double-click, as Mail opens a message: in a window of its own.
            guard let id = ids.first else { return }
            openWindow(value: WindowTarget(hostID: window.hostID, threadID: id))
        }
        .overlay { emptyState(isEmpty: sections.isEmpty) }
        // A directory dragged from Finder onto the list starts a new chat in it; this Mac's only.
        .dropDestination(for: URL.self, isEnabled: window.connection?.host.isLocal == true) { urls, _ in
            if let folder = urls.first(where: \.hasDirectoryPath) { newChat(in: folder.path) }
        }
        .accessibilityDropPoint(.center, description: Text("New Chat in Directory"))
        // ⌫ archives the selected chat, as Mail's does a message; Edit ▸ Undo brings it back.
        .onDeleteCommand {
            if let thread = window.selectedThread, !thread.isArchived { window.setArchived([thread], true) }
        }
    }

    // MARK: rows

    private struct ResolvedRow: Identifiable {
        let id: String
        let thread: ThreadModel
        /// Pinned, and not archived: what Pinned lists, and Activity marks.
        let isPinned: Bool
    }

    private struct ResolvedSection: Identifiable {
        let id: String
        let title: String
        let help: String?
        let folder: String?
        let rows: [ResolvedRow]
    }

    /// Chats paired with their live models before the `ForEach`, so neither a row nor a section
    /// in the list can build to nothing: the sidebar's outline list traps on an empty item.
    private func resolve(_ sections: [SidebarSection], _ byID: [String: ThreadModel]) -> [ResolvedSection] {
        sections.compactMap { section in
            let rows = section.chats.compactMap { chat in
                byID[chat.id].map { ResolvedRow(id: chat.id, thread: $0, isPinned: chat.isPinned && !chat.isArchived) }
            }
            guard !rows.isEmpty else { return nil }
            return ResolvedSection(id: section.id, title: section.title, help: section.help, folder: section.folder, rows: rows)
        }
    }

    @ViewBuilder private func rowView(_ row: ResolvedRow, in section: ResolvedSection) -> some View {
        if window.renamingInPlace === row.thread {
            ChatRenameField(window: window, thread: row.thread)
        } else {
            chatRow(row, in: section)
        }
    }

    @ViewBuilder private func chatRow(_ row: ResolvedRow, in section: ResolvedSection) -> some View {
        switch appearance.sidebar {
        case .activity:
            ActivityRow(thread: row.thread, isPinned: row.isPinned)
        case .chats:
            // Pinned names no folder, so its rows do, as a date section's rows do.
            ChatRow(thread: row.thread, grouping: section.id == SidebarSection.pinnedID ? .date : app.sidebarGrouping)
        }
    }

    /// Swiped from the trailing edge, as in Mail.
    @ViewBuilder private func archiveSwipe(_ thread: ThreadModel) -> some View {
        if thread.isArchived {
            Button("Unarchive", systemImage: "tray.and.arrow.up") { window.setArchived([thread], false) }
                .tint(.blue)
        } else {
            Button("Archive", systemImage: "archivebox") { window.setArchived([thread], true) }
                .tint(.purple)
        }
    }

    @ViewBuilder private func header(_ section: ResolvedSection) -> some View {
        if let folder = section.folder {
            Text(section.title)
                .help(section.help ?? "")
                .contextMenu { folderMenu(folder, section) }
        } else if let help = section.help {
            Text(section.title).help(help)
        } else {
            Text(section.title)
        }
    }

    // MARK: folders

    private func newChat(in folder: String) {
        window.newChat()
        window.draftDirectory = folder
    }

    @ViewBuilder private func folderMenu(_ folder: String, _ section: ResolvedSection) -> some View {
        Button("New Chat Here") { newChat(in: folder) }
        if window.connection?.host.isLocal == true {
            Button("Show in Finder") { Finder.show(directory: folder) }
        }
        // What's listed under the header; none of it when the list shows only archived chats.
        let unarchived = section.rows.map(\.thread).filter { !$0.isArchived }
        if !unarchived.isEmpty, window.connection != nil {
            Divider()
            // No confirmation: Edit ▸ Undo brings them all back.
            Button("Archive Chats in Directory") { window.setArchived(unarchived, true) }
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

    @ViewBuilder private func menu(for ids: Set<String>, in byID: [String: ThreadModel]) -> some View {
        if let id = ids.first, let thread = byID[id] {
            ChatActionItems(window: window, thread: thread, hidesUnavailable: true)
        } else {
            // Activity lists by day whatever the grouping, so it isn't offered there.
            if appearance.sidebar == .chats {
                Picker("Group By", selection: Bindable(app).sidebarGrouping) {
                    ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
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
            case .failed, .disconnected, .needsNode:
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

/// A chat's row while it's renamed in place: its title in a field, committed on Return or when the
/// field loses focus, and put back on Esc.
struct ChatRenameField: View {
    let window: WindowModel
    let thread: ThreadModel
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $title)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { window.renamingInPlace = nil }
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear {
                title = thread.title
                focused = true
            }
    }

    private func commit() {
        guard window.renamingInPlace === thread else { return }
        window.renamingInPlace = nil
        window.rename(thread, to: title)
    }
}

/// A host that isn’t connected, and how to connect it: the sidebar’s empty state, and the Scheduled
/// Tasks window’s. A chat and New Chat say it with `ConnectionStatusCard` instead.
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
        case .needsNode(let need):
            ContentUnavailableView {
                Label(need.title, systemImage: "shippingbox")
            } description: {
                Text(need.detail(host: connection.host.name))
            } actions: {
                if let copy = need.copy {
                    Button(need.installTitle) { Task { await connection.copyServer(copy) } }
                        .disabled(connection.isCopying)
                }
                Button("Check Again") { Task { await connection.connect() } }
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
    .environment(\.appearance, app.appearance)
    .frame(width: 900, height: 640)
}

/// The sample host with two chats pinned: one from today, one from a few days ago.
@MainActor
private func pinningSample(_ app: AppModel = .sample()) -> AppModel {
    let pinned = ["Explain ThreadModel's turn tracking", "Bump the pinned server version"]
    for chat in app.connection(app.lastHostID)?.chats ?? [] where pinned.contains(chat.title) {
        app.setPinned(true, chat.id, on: app.lastHostID)
    }
    return app
}

#Preview("Sidebar (by date)") {
    sidebarPreview(.sample())
}

#Preview("Sidebar (by directory)") {
    let app = AppModel.sample()
    app.sidebarGrouping = .directory
    return sidebarPreview(app)
}

#Preview("Sidebar (pinned)") {
    sidebarPreview(pinningSample())
}

/// Pinned stays on top whatever the grouping, and its chats aren't repeated in their folders.
#Preview("Sidebar (pinned, by directory)") {
    let app = pinningSample()
    app.sidebarGrouping = .directory
    return sidebarPreview(app)
}

/// Settings ▸ Advanced ▸ Sidebar ▸ Activity, the alternative appearance: Needs You, then by day.
/// Only chats opened this launch have a reply to preview; `thread/list` carries none.
#Preview("Sidebar (activity)") {
    let app = pinningSample()
    app.appearance.sidebar = .activity
    return sidebarPreview(app)
}

/// New Chat Here is a section action: the system shows it while the pointer is over the section,
/// which a preview can't do.
#Preview("Directory sections") {
    List {
        Section {
            ChatRow(thread: .sampleIdleChat(), grouping: .directory)
        } header: {
            Text("tether-app")
        }
        .sectionActions { Button("New Chat Here", systemImage: "square.and.pencil") {} }
    }
    .listStyle(.sidebar)
    .frame(width: 280, height: 120)
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

/// A host without Node.js: Install Tether, and Check Again.
#Preview("Sidebar (host without Node.js)") {
    let host = HostConnection.sampleNeedsNode()
    return sidebarPreview(.sample(connections: [.sample(), host]), host: host.id)
}

#Preview("Sidebar (no search results)") {
    sidebarPreview(.sample(), search: "kubernetes")
}
#endif
