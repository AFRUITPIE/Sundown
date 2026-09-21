import SwiftUI
import TetherKit
import TetherProtocol

public struct RootView: View {
    @Bindable var app: AppModel
    @State private var inspectedTaskID: String?

    public init(app: AppModel) {
        self.app = app
    }

    // No columnVisibility binding: writing it on every sidebar toggle rebuilt the toolbar mid-animation.
    public var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailView(app: app)
                // Title, subtitle and toolbar belong to the container, not to whichever screen is inside it:
                // every item is then declared once and unconditionally, so nothing moves on selection.
                .navigationTitle(app.selectedThread?.title ?? "New Chat")
                .navigationSubtitle(app.selectedThread?.cwd?.abbreviatingHome ?? "")
                .toolbar {
                    ToolbarItem(placement: .navigation) { NewChatButton(app: app) }
                    ToolbarItem(placement: .principal) { SessionControls(app: app) }
                }
        }
        // Attached to the split view, so it is full height and present on every screen.
        .inspector(isPresented: $app.showInspector) {
            InspectorView(app: app, selectedTaskID: $inspectedTaskID)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                // Declared by the inspector so the toggle sits above its column.
                .toolbar {
                    Spacer()
                    InspectorToggle(isPresented: $app.showInspector)
                }
        }
        .environment(\.inspectSubagent, InspectSubagentAction { toolUseId in
            inspectedTaskID = toolUseId
            app.showInspector = true
        })
        .environment(\.readingWidth, app.transcriptWidth.points)
        .task { app.connectAll() }
    }
}

/// The selected chat, or the New Chat form. One container, so the detail column is never torn down.
struct DetailView: View {
    @Bindable var app: AppModel

    var body: some View {
        if let thread = app.selectedThread, let connection = app.connection {
            // The only `.id()` in the shell: a different chat gets its own composer draft and scroll position.
            ThreadView(thread: thread, connection: connection)
                .id(thread.id)
        } else {
            NewChatView(app: app)
        }
    }
}

struct NewChatButton: View {
    let app: AppModel

    var body: some View {
        Button {
            app.newChat()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel("New Chat")
        .help("New Chat (⌘N)")
    }
}

/// Session controls for the selected chat, or for the New Chat draft. The branch is inside the
/// toolbar item's view, never around the item itself.
struct SessionControls: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 4) {
            if let thread = app.selectedThread, let connection = app.connection {
                ThreadControls(thread: thread, connection: connection)
            } else if let connection = app.connection {
                NewChatControls(app: app, connection: connection)
            }
        }
    }
}

/// The inspector's content: the selected chat's, or a placeholder so the column is never blank.
struct InspectorView: View {
    let app: AppModel
    @Binding var selectedTaskID: String?

    var body: some View {
        if let thread = app.selectedThread, let connection = app.connection {
            ThreadInspector(thread: thread, connection: connection, selectedTaskID: $selectedTaskID)
                // Already in the inspector: showing a subagent only changes which task is selected.
                .environment(\.inspectSubagent, InspectSubagentAction { selectedTaskID = $0 })
        } else {
            ContentUnavailableView("No Session", systemImage: "sidebar.trailing")
        }
    }
}

/// A plain button, not a `Toggle`: a toggle would tint itself on, unlike every other toolbar control.
/// ⌥⌘I lives on the View menu instead, which works whether or not the inspector is open.
struct InspectorToggle: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .accessibilityLabel("Inspector")
        .help(isPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
    }
}

/// View-menu items for the shell. Kept here with the views they drive.
public struct ShellViewCommands: View {
    @Bindable var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Picker("Group By", selection: $app.sidebarGrouping) {
            ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Divider()
        // The one claim on ⌥⌘I: a menu command works with the inspector open or closed.
        Button(app.showInspector ? "Hide Inspector" : "Show Inspector") { app.showInspector.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
    }
}

/// Compose a new chat: choose the host and working directory, then send the first message.
struct NewChatView: View {
    @Bindable var app: AppModel
    @Environment(\.readingWidth) private var readingWidth
    @State private var directory: String?
    @State private var error: String?
    @State private var choosingLocalFolder = false
    @State private var choosingRemoteFolder = false

    /// The same host the sidebar shows, so its chats and this draft always agree.
    private var connection: HostConnection? { app.connection }

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: $app.hostID) {
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
        .onChange(of: app.hostID) {
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
            app.open(threadID: t.id, on: connection.id)
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
    if let chat = app.connection?.chats.first { app.open(threadID: chat.id) }
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

// The narrowest supported window: every toolbar item must still fit.
// The preview host cannot resize, so a third column here loops its constraint pass; the
// running app at the same width is fine, and "RootView (inspector open)" covers that case.
#Preview("RootView (narrow window)") {
    RootView(app: rootPreviewApp())
        .frame(width: 900, height: 600)
}

#Preview("NewChatView") {
    NavigationStack {
        NewChatView(app: .sample())
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
