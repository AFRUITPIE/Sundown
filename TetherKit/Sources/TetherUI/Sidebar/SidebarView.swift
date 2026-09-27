import AppKit
import SwiftUI
import TetherKit

/// The chats of the one host the window is showing: grouped, searchable, and with a single
/// context menu for the whole list.
struct SidebarView: View {
    @Bindable var window: WindowModel
    @State private var search: String
    /// The folder whose chats Archive Chats in Folder… is asking about.
    @State private var archivingFolder: FolderArchive?
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
                        rowView(row, in: section)
                            .tag(row.id)
                            // The full title, for one the column truncates.
                            .help(row.thread.title)
                            .swipeActions(edge: .trailing) { archiveSwipe(row.thread) }
                    }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search Chats")
        // One menu for the list: the row's when a row was hit, the list's own when the empty area was.
        .contextMenu(forSelectionType: String.self) { menu(for: $0, in: byID) } primaryAction: { ids in
            // Double-click, as Mail opens a message: in a window of its own.
            guard let id = ids.first else { return }
            openWindow(value: WindowTarget(hostID: window.hostID, threadID: id))
        }
        .overlay { emptyState(isEmpty: sections.isEmpty) }
        // A folder dragged from Finder onto the list starts a new chat in it.
        .dropDestination(for: URL.self) { urls, _ in
            guard window.connection?.host.isLocal == true, let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            newChat(in: folder.path)
            return true
        }
        .alert(archiveTitle, isPresented: Binding(get: { archivingFolder != nil }, set: { if !$0 { archivingFolder = nil } })) {
            Button("Archive") {
                if let archive = archivingFolder { window.setArchived(archive.threads, true) }
                archivingFolder = nil
            }
            Button("Cancel", role: .cancel) { archivingFolder = nil }
        } message: {
            Text("View ▸ Show ▸ Archived lists them again.")
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
            FolderHeader(title: section.title, help: section.help, newChat: { newChat(in: folder) })
                .contextMenu { folderMenu(folder, section) }
        } else if let help = section.help {
            Text(section.title).help(help)
        } else {
            Text(section.title)
        }
    }

    // MARK: folders

    private struct FolderArchive {
        let name: String
        let threads: [ThreadModel]
    }

    private var archiveTitle: Text {
        let count = archivingFolder?.threads.count ?? 0
        return Text("Archive ^[\(count) Chat](inflect: true) in “\(archivingFolder?.name ?? "")”?")
    }

    private func newChat(in folder: String) {
        window.newChat()
        window.draftDirectory = folder
    }

    @ViewBuilder private func folderMenu(_ folder: String, _ section: ResolvedSection) -> some View {
        Button("New Chat Here") { newChat(in: folder) }
        if window.connection?.host.isLocal == true {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
        }
        // What's listed under the header; none of it when the list shows only archived chats.
        let unarchived = section.rows.map(\.thread).filter { !$0.isArchived }
        if !unarchived.isEmpty, window.connection != nil {
            Divider()
            Button("Archive Chats in Folder…") { archivingFolder = FolderArchive(name: section.title, threads: unarchived) }
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
        case .connecting, .connected:
            EmptyView()
        }
    }
}

/// A folder section's header: New Chat Here appears on hover, as a section's actions do in a
/// Finder or Mail sidebar. VoiceOver reaches it as the header's action instead.
struct FolderHeader: View {
    let title: String
    let help: String?
    let newChat: () -> Void
    @State private var hovering: Bool

    /// `hovering` is a parameter only so a preview can show the button.
    init(title: String, help: String?, hovering: Bool = false, newChat: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.newChat = newChat
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer(minLength: 0)
            Button("New Chat Here", systemImage: "square.and.pencil", action: newChat)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Chat Here")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(true)
        }
        .help(help ?? "")
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "New Chat Here", newChat)
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

#Preview("Folder header (hovered)") {
    List {
        Section {
            ChatRow(thread: .sampleIdleChat(), grouping: .directory)
        } header: {
            FolderHeader(title: "tether-app", help: "~/Code/tether-app", hovering: true) {}
        }
        Section {
            ChatRow(thread: .sampleListed(title: "Trace the reconnect path", cwd: "/Users/hayden/Code/tether-server",
                                          secondsAgo: 90_000), grouping: .directory)
        } header: {
            FolderHeader(title: "tether-server", help: "~/Code/tether-server") {}
        }
    }
    .listStyle(.sidebar)
    .frame(width: 280, height: 200)
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
