import SwiftUI
import TetherKit

/// One window: creates its `WindowModel` once, starts it when the window appears and lets its chat
/// go when the window closes, and hands it to the menu bar while the window is frontmost.
public struct WindowRoot: View {
    @State private var window: WindowModel

    public init(app: AppModel, target: WindowTarget? = nil) {
        // Side-effect free until `start()`, so a discarded instance leaves nothing behind.
        _window = State(initialValue: WindowModel(app: app, target: target))
    }

    public var body: some View {
        RootView(window: window)
            .focusedSceneValue(\.window, window)
            .onAppear { window.start() }
            .onDisappear { window.close() }
    }
}

public struct RootView: View {
    @Bindable var window: WindowModel
    @State private var inspectedTaskID: String?
    /// Whether the inspector has finished opening; see `minWidth`.
    @State private var inspectorSettled = true

    public init(window: WindowModel) {
        self.window = window
    }

    private var app: AppModel { window.app }

    public var body: some View {
        // No columnVisibility binding: writing it on every sidebar toggle rebuilt the toolbar mid-animation.
        NavigationSplitView {
            SidebarView(window: window)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailView(window: window)
                // Title, subtitle and toolbar belong to the container, not to whichever screen is inside it:
                // every item is then declared once and unconditionally, so nothing moves on selection.
                .navigationTitle(window.selectedThread?.title ?? "New Chat")
                .navigationSubtitle(window.subtitle)
                // Identified, so View ▸ Customize Toolbar… can rearrange these and the window
                // remembers the arrangement. Every item is still declared unconditionally.
                .toolbar(id: "main") {
                    ToolbarItem(id: "newChat", placement: .navigation) { NewChatButton(window: window) }
                    ToolbarItem(id: "session", placement: .primaryAction) {
                        ToolbarSessionControl(window: window, control: SessionMenus.init(settings:))
                    }
                    // Keeps the chat's settings apart from the inspector button beside them.
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
        }
        // Attached to the split view, so it is full height and present on every screen.
        .inspector(isPresented: $window.showInspector) {
            InspectorView(window: window, selectedTaskID: $inspectedTaskID)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem { InspectorToggle(window: window) }
                }
        }
        // Reaches the inspector too, whose task list shows subagents the same way.
        .environment(\.inspectSubagent, InspectSubagentAction(owner: window) { toolUseId in
            inspectedTaskID = toolUseId
            window.openInspector(on: .tasks)
        })
        .environment(\.readingWidth, app.transcriptWidth.points)
        .environment(\.composerDrafts, ComposerDrafts(app: app))
        .frame(minWidth: minWidth, minHeight: 400)
        .onChange(of: window.showInspector) { _, shown in
            inspectorSettled = false
            guard shown else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if window.showInspector { inspectorSettled = true }
            }
        }
        .chatActionAlerts(window)
        .task { app.connectAll() }
    }

    /// The columns' minimums (sidebar 220, detail 520, inspector 260). While the inspector opens
    /// there is none: AppKit then grows a narrow window along with the inspector's animation,
    /// where a minimum raised at the same moment jumps it wider first. Once open, the minimum
    /// replaces the one AppKit leaves behind, which is the window's whole width at that point.
    private var minWidth: CGFloat? {
        guard window.showInspector else { return 740 }
        return inspectorSettled ? 1000 : nil
    }
}

/// The selected chat, or the New Chat screen. One container, so the detail column is never torn down.
struct DetailView: View {
    @Bindable var window: WindowModel

    var body: some View {
        // The column's root keeps one identity. When the root itself changed (the branch, or the
        // chat's `.id`), the column's toolbar items were torn down and rebuilt, fading in on every switch.
        ZStack {
            if let thread = window.selectedThread, let connection = window.connection {
                // The only `.id()` in the shell: a different chat gets its own composer draft and scroll position.
                ThreadView(thread: thread, connection: connection)
                    .id(thread.id)
            } else {
                NewChatView(window: window)
            }
        }
    }
}

struct NewChatButton: View {
    let window: WindowModel

    var body: some View {
        Button {
            window.newChat()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("New Chat")
        .help("Start a chat in a new or recent folder")
    }
}

/// File ▸ New Chat and New Window. New Chat acts on the frontmost window, opening one if there is
/// none; a new window starts on New Chat, on the frontmost window's host.
public struct FileCommands: View {
    let app: AppModel
    @FocusedValue(\.window) private var window
    @Environment(\.openWindow) private var openWindow

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Button("New Chat") {
            if let window { window.newChat() } else { openWindow(value: WindowTarget(hostID: app.lastHostID)) }
        }
        .keyboardShortcut("n")
        Button("New Window") {
            openWindow(value: WindowTarget(hostID: window?.hostID ?? app.lastHostID))
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
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

/// View-menu items for the shell. Kept here with the views they drive. The inspector items act on
/// the frontmost window, and are disabled when there is none.
public struct ShellViewCommands: View {
    @Bindable var app: AppModel
    @FocusedValue(\.window) private var window

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
                Toggle(pane.label, isOn: Binding(get: { window?.isInspecting(pane) ?? false },
                                                 set: { _ in window?.openInspector(on: pane) }))
                    .keyboardShortcut(pane.shortcut, modifiers: [.command, .option])
            }
        }
        .disabled(window == nil)
        Button(window?.showInspector == true ? "Hide Inspector" : "Show Inspector") { window?.showInspector.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(window == nil)
    }
}

#if DEBUG
// #Preview bodies are result-builder closures (no `if`/control flow), so the selection is set here.
@MainActor
private func rootPreviewWindow() -> WindowModel {
    let app = AppModel.sample()
    return .sample(app, threadID: app.connection(app.lastHostID)?.chats.first?.id)
}

#Preview("RootView") {
    RootView(window: rootPreviewWindow())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (default new chat)") {
    RootView(window: .sample())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (inspector open)") {
    let window = rootPreviewWindow()
    window.showInspector = true
    return RootView(window: window)
        .frame(width: 1160, height: 760)
}

#Preview("RootView (wide transcript)") {
    let window = rootPreviewWindow()
    window.app.transcriptWidth = .wide
    return RootView(window: window)
        .frame(width: 1400, height: 760)
}

// The narrowest window without the inspector: every toolbar item must still fit.
// The inspector preview uses the wider minimum that TetherApp applies while it is open.
#Preview("RootView (narrow window)") {
    RootView(window: rootPreviewWindow())
        .frame(width: 900, height: 600)
}

#endif
