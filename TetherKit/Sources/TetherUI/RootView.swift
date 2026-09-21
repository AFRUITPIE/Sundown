import SwiftUI
import TetherKit

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
                // Identified, so View ▸ Customize Toolbar… can rearrange these and the window
                // remembers the arrangement. Every item is still declared unconditionally.
                .toolbar(id: "main") {
                    ToolbarItem(id: "newChat", placement: .navigation) { NewChatButton(app: app) }
                    ToolbarItem(id: "model", placement: .principal) { ModelMenu(settings: .current(app)) }
                    ToolbarItem(id: "effort", placement: .principal) { EffortMenu(settings: .current(app)) }
                    ToolbarItem(id: "permissions", placement: .principal) { PermissionsMenu(settings: .current(app)) }
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

#endif
