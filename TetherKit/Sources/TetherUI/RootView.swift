import SwiftUI
import TetherKit

public struct RootView: View {
    @Bindable var app: AppModel
    @State private var inspectedTaskID: String?
    /// Whether the inspector has finished opening; see `minWidth`.
    @State private var inspectorSettled = true

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        // No columnVisibility binding: writing it on every sidebar toggle rebuilt the toolbar mid-animation.
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailView(app: app)
                // Title, subtitle and toolbar belong to the container, not to whichever screen is inside it:
                // every item is then declared once and unconditionally, so nothing moves on selection.
                .navigationTitle(app.selectedThread?.title ?? "New Chat")
                .navigationSubtitle(app.subtitle)
                // Identified, so View ▸ Customize Toolbar… can rearrange these and the window
                // remembers the arrangement. Every item is still declared unconditionally.
                .toolbar(id: "main") {
                    ToolbarItem(id: "newChat", placement: .navigation) { NewChatButton(app: app) }
                    ToolbarItem(id: "session", placement: .primaryAction) {
                        ToolbarSessionControl(app: app, control: SessionMenus.init(settings:))
                    }
                    // Keeps the chat's settings apart from the inspector button beside them.
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
        }
        // Attached to the split view, so it is full height and present on every screen.
        .inspector(isPresented: $app.showInspector) {
            InspectorView(app: app, selectedTaskID: $inspectedTaskID)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem { InspectorToggle(app: app) }
                }
        }
        // Reaches the inspector too, whose task list shows subagents the same way.
        .environment(\.inspectSubagent, InspectSubagentAction(owner: app) { toolUseId in
            inspectedTaskID = toolUseId
            app.openInspector(on: .tasks)
        })
        .environment(\.readingWidth, app.transcriptWidth.points)
        .frame(minWidth: minWidth, minHeight: 400)
        .onChange(of: app.showInspector) { _, shown in
            inspectorSettled = false
            guard shown else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if app.showInspector { inspectorSettled = true }
            }
        }
        .task { app.connectAll() }
    }

    /// The columns' minimums (sidebar 220, detail 520, inspector 260). While the inspector opens
    /// there is none: AppKit then grows a narrow window along with the inspector's animation,
    /// where a minimum raised at the same moment jumps it wider first. Once open, the minimum
    /// replaces the one AppKit leaves behind, which is the window's whole width at that point.
    private var minWidth: CGFloat? {
        guard app.showInspector else { return 740 }
        return inspectorSettled ? 1000 : nil
    }
}

/// The selected chat, or the New Chat screen. One container, so the detail column is never torn down.
struct DetailView: View {
    @Bindable var app: AppModel

    var body: some View {
        // The column's root keeps one identity. When the root itself changed (the branch, or the
        // chat's `.id`), the column's toolbar items were torn down and rebuilt, fading in on every switch.
        ZStack {
            if let thread = app.selectedThread, let connection = app.connection {
                // The only `.id()` in the shell: a different chat gets its own composer draft and scroll position.
                ThreadView(thread: thread, connection: connection)
                    .id(thread.id)
            } else {
                NewChatView(app: app)
            }
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
        .accessibilityLabel("New Chat")
        .help("New Chat (⌘N)")
    }
}

/// The transcript width as a View submenu with the current value checked. Also in Settings ▸
/// General, so changing it doesn't mean opening Settings.
public struct TranscriptWidthCommands: View {
    @Bindable var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Picker("Transcript Width", selection: $app.transcriptWidth) {
            ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
        }
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
            ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Divider()
        // A shortcut always shows its pane, opening the inspector if needed; ⌥⌘I hides it.
        Menu("Inspector") {
            ForEach(InspectorPane.allCases) { pane in
                Toggle(pane.label, isOn: Binding(get: { app.isInspecting(pane) },
                                                 set: { _ in app.openInspector(on: pane) }))
                    .keyboardShortcut(pane.shortcut, modifiers: [.command, .option])
            }
        }
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
        .frame(width: 1160, height: 760)
}

#Preview("RootView (wide transcript)") {
    let app = rootPreviewApp()
    app.transcriptWidth = .wide
    return RootView(app: app)
        .frame(width: 1400, height: 760)
}

// The narrowest window without the inspector: every toolbar item must still fit.
// The inspector preview uses the wider minimum that TetherApp applies while it is open.
#Preview("RootView (narrow window)") {
    RootView(app: rootPreviewApp())
        .frame(width: 900, height: 600)
}

#endif
