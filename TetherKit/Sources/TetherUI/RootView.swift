import SwiftUI
import TetherKit

/// One window: creates its `WindowModel` once, starts it when the window appears and lets its chat
/// go when the window closes, and hands it to the menu bar while the window is frontmost.
public struct WindowRoot: View {
    @State private var window: WindowModel
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    public init(app: AppModel, target: WindowTarget? = nil) {
        // Side-effect free until `start()`, so a discarded instance leaves nothing behind.
        _window = State(initialValue: WindowModel(app: app, target: target))
    }

    public var body: some View {
        RootView(window: window)
            .focusedSceneValue(\.window, window)
            .onAppear {
                window.start()
                // So a notification or the Dock menu can open a window when none is left.
                let open = openWindow
                window.app.openWindow = { open(value: $0) }
            }
            .onDisappear { window.close() }
            .onChange(of: appearsActive, initial: true) {
                window.isKey = appearsActive
                if appearsActive { window.app.activate(window) }
            }
            // The floating inspector panel follows the app's state, whichever window changed it.
            .onChange(of: window.app.inspectorPanelShown) { _, shown in
                if shown { openWindow(id: InspectorPanel.id) } else { dismissWindow(id: InspectorPanel.id) }
            }
            // Leaving the panel for another placement closes it; its state carries to this window.
            .onChange(of: window.app.appearance.inspector) { old, new in
                guard old != new else { return }
                if old == .panel, window.app.inspectorPanelShown {
                    window.app.inspectorPanelShown = false
                    if window.isKey { window.showInspector = true }
                } else if new == .panel, window.isKey, window.showInspector {
                    window.app.inspectorPanelShown = true
                }
            }
    }
}

public struct RootView: View {
    @Bindable var window: WindowModel

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
                    // Settings ▸ Advanced ▸ Session Controls picks which of these two shows: all three
                    // menus, or (Split) permissions alone; Message Field shows neither. Hidden, not
                    // removed, and neither item's menus ever change: when one item's menus came and
                    // went instead, AppKit's toolbar layout asserted (an index past `_currentItems`)
                    // as previews switched on New Chat.
                    ToolbarItem(id: "session", placement: .primaryAction) {
                        ToolbarSessionControl(window: window, control: SessionMenus.init(settings:))
                    }
                    .hidden(sessionControls != .toolbar)
                    ToolbarItem(id: "permissions", placement: .primaryAction) {
                        ToolbarSessionControl(window: window, control: PermissionsMenu.init(settings:))
                    }
                    .hidden(sessionControls != .split)
                    // Keeps the chat's settings apart from the inspector button beside them.
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
        }
        // Attached to the split view, so it is full height and present on every screen. Presented only
        // when Settings ▸ Advanced ▸ Inspector puts it beside the chat; its toolbar button stays
        // either way, and shows the inspector wherever it is.
        .inspector(isPresented: columnInspector) {
            InspectorView(window: window, selectedTaskID: $window.inspectedTaskID)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem { InspectorToggle(window: window) }
                }
        }
        // Reaches the inspector too, whose task list shows subagents the same way.
        .environment(\.inspectSubagent, InspectSubagentAction(owner: window) { toolUseId in
            window.inspectedTaskID = toolUseId
            window.openInspector(on: .tasks)
        })
        .environment(\.restoreCode, ForkChatAction(owner: window) { window.restoreCode(before: $0) })
        .environment(\.startSuggestedTask, StartSuggestedTaskAction(owner: window) { window.startSuggestedTask($0, from: $1) })
        .environment(\.openChat, ForkChatAction(owner: window) { id in
            // A desktop session's id carries a prefix ("local_…"); Claude Code's own is the rest.
            let bare = id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? id
            let known = window.connection?.chats.first { $0.id == id || $0.id == bare }
            if let known { window.open(threadID: known.id) }
        })
        .environment(\.showInspectorPane, ShowInspectorPaneAction(owner: window) { window.openInspector(on: $0) })
        .environment(\.forkChat, ForkChatAction(owner: window) { messageID in
            guard let thread = window.selectedThread, let connection = window.connection else { return }
            Task { if let fork = await connection.fork(thread, at: messageID) { window.open(threadID: fork.id) } }
        })
        .environment(\.readingWidth, app.transcriptWidth.points)
        .environment(\.textScale, app.textScale)
        .environment(\.appearance, app.appearance)
        .environment(\.hostIsLocal, window.connection?.host.isLocal == true)
        .environment(\.openFilesWith, app.appearance.openFilesWith)
        .environment(\.transcriptFind, window.find)
        .environment(\.promptNavigator, window.prompts)
        .environment(\.composerDrafts, ComposerDrafts(app: app))
        .frame(minWidth: minWidth, minHeight: 400)
        .chatActionAlerts(window)
        .task { app.connectAll() }
    }

    private var sessionControls: Appearance.SessionControlsPlacement { app.appearance.sessionControls }

    /// The sidebar's and detail's minimums (220 + 520) while the inspector column is closed. While
    /// it's open there is none: SwiftUI then keeps the window at least as wide as its columns, and an
    /// explicit minimum below that let the window shrink under them, clipping the sidebar and the
    /// inspector at both edges.
    private var minWidth: CGFloat? {
        app.appearance.inspector == .column && window.showInspector ? nil : 740
    }

    /// The inspector column, open only in its placement.
    private var columnInspector: Binding<Bool> {
        Binding(get: { app.appearance.inspector == .column && window.showInspector },
                set: { window.showInspector = $0 })
    }
}

/// The selected chat, or the New Chat screen. One container, so the detail column is never torn down.
struct DetailView: View {
    @Bindable var window: WindowModel

    var body: some View {
        // The column's root keeps one identity. When the root itself changed (the branch, or the
        // chat's `.id`), the column's toolbar items were torn down and rebuilt, fading in on every switch.
        // A split view only for Settings ▸ Advanced ▸ Inspector ▸ Drawer, holding the drawer while
        // it's open, so opening it doesn't change the column's root. Not always: a split view here
        // beside the inspector column sent AppKit into its Update Constraints loop at launch.
        // Changing the placement rebuilds the column, which is fine for a setting.
        if placement == .drawer {
            VSplitView {
                chat.frame(minHeight: 240)
                if window.showInspector {
                    InspectorDrawer(window: window)
                }
            }
        } else {
            chat
        }
    }

    /// The chat or New Chat. The chat and New Chat place Settings ▸ Advanced ▸ Inspector ▸ Over the
    /// Chat's card themselves, above their bottom bars.
    private var chat: some View {
        ZStack {
            if let thread = window.selectedThread, let connection = window.connection {
                // The only `.id()` in the shell: a different chat gets its own composer draft and scroll position.
                ThreadView(thread: thread, connection: connection)
                    .id(thread.id)
            } else {
                NewChatView(window: window)
            }
        }
        .environment(\.inspectorCardWindow, window)
    }

    private var placement: Appearance.InspectorPlacement { window.app.appearance.inspector }
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
        .help("New Chat")
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

/// Edit ▸ Find, for the frontmost window's chat: Find… opens the bar over the transcript, and Find
/// Next and Previous step through what it matched. Dimmed on New Chat, where there's nothing to find.
public struct FindCommands: View {
    @FocusedValue(\.window) private var window

    public init() {}

    public var body: some View {
        let find = window?.selectedThread == nil ? nil : window?.find
        Menu("Find") {
            Button("Find…") { find?.show() }
                .keyboardShortcut("f")
            Button("Find Next") { if find?.isPresented == true { find?.next() } else { find?.show() } }
                .keyboardShortcut("g")
            Button("Find Previous") { if find?.isPresented == true { find?.previous() } else { find?.show() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .disabled(find == nil)
    }
}

/// The Help menu: Tether's own documentation, then Claude Code's, which covers what the chats run.
public struct HelpCommands: View {
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        Button("Tether Help") { openURL(URL(string: "https://github.com/AFRUITPIE/tether-app#readme")!) }
            .keyboardShortcut("?")
        Button("Claude Code Documentation") { openURL(URL(string: "https://code.claude.com/docs/en/overview")!) }
    }
}

/// View ▸ Bigger, Smaller and Actual Size, for the transcript and composer's text.
public struct TextSizeCommands: View {
    @Bindable var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Button("Bigger") { if let next = TextScale.bigger(than: app.textScale) { app.textScale = next } }
            .keyboardShortcut("+")
            .disabled(TextScale.bigger(than: app.textScale) == nil)
        Button("Smaller") { if let next = TextScale.smaller(than: app.textScale) { app.textScale = next } }
            .keyboardShortcut("-")
            .disabled(TextScale.smaller(than: app.textScale) == nil)
        Button("Actual Size") { app.textScale = 1 }
            .keyboardShortcut("0")
            .disabled(app.textScale == 1)
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
        // Activity lists by day, whatever the grouping.
        .disabled(app.appearance.sidebar == .activity)
        Picker("Show", selection: $app.sidebarFilter) {
            ForEach(SidebarFilter.allCases, id: \.self) { Text($0.label).tag($0) }
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
        Button(window?.inspectorShown == true ? "Hide Inspector" : "Show Inspector") { window?.inspectorShown.toggle() }
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
    window.app.appearance.inspector = .column
    window.showInspector = true
    return RootView(window: window)
        .frame(width: 1160, height: 760)
}

/// Settings ▸ Advanced ▸ Inspector: under the chat, and over it.
#Preview("RootView (inspector drawer)") {
    let window = rootPreviewWindow()
    window.app.appearance.inspector = .drawer
    window.showInspector = true
    return RootView(window: window)
        .frame(width: 1100, height: 760)
}

#Preview("RootView (inspector over the chat)") {
    let window = rootPreviewWindow()
    window.app.appearance.inspector = .overlay
    window.showInspector = true
    return RootView(window: window)
        .frame(width: 1100, height: 760)
}

#Preview("RootView (wide transcript)") {
    let window = rootPreviewWindow()
    window.app.transcriptWidth = .wide
    return RootView(window: window)
        .frame(width: 1400, height: 760)
}

#Preview("RootView (bigger text)") {
    let window = rootPreviewWindow()
    window.app.textScale = 1.5
    return RootView(window: window)
        .frame(width: 1100, height: 760)
}

/// Settings ▸ Advanced ▸ Session Controls: the toolbar keeps only what the message field doesn't
/// hold — nothing for Message Field, permissions alone for Split.
@MainActor
private func rootPreview(_ placement: Appearance.SessionControlsPlacement, newChat: Bool = false) -> some View {
    let window = newChat ? WindowModel.sample() : rootPreviewWindow()
    window.app.appearance.sessionControls = placement
    return RootView(window: window)
        .frame(width: 1100, height: 760)
}

#Preview("RootView (session controls in message field)") { rootPreview(.messageField) }
#Preview("RootView (session controls split)") { rootPreview(.split) }
#Preview("RootView (new chat, session controls in message field)") { rootPreview(.messageField, newChat: true) }
#Preview("RootView (new chat, session controls split)") { rootPreview(.split, newChat: true) }

// The narrowest window without the inspector: every toolbar item must still fit.
// The inspector preview uses the wider minimum that TetherApp applies while it is open.
#Preview("RootView (narrow window)") {
    RootView(window: rootPreviewWindow())
        .frame(width: 900, height: 600)
}

#endif
