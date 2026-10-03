import SwiftUI
import TetherKit

/// One window: creates its `WindowModel` once, starts it when the window appears and lets its chat
/// go when the window closes, and hands it to the menu bar while the window is frontmost. Keeps the
/// scene's value on what the window shows, and its inspector in scene storage, so the system
/// restores each window as it was.
public struct WindowRoot: View {
    @State private var window: WindowModel
    @Binding private var target: WindowTarget
    @SceneStorage("showInspector") private var storedShowInspector: Bool?
    @SceneStorage("inspectorPane") private var storedInspectorPane: InspectorPane?
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.undoManager) private var undoManager

    public init(app: AppModel, target: Binding<WindowTarget>) {
        _target = target
        // Side-effect free until `start()`, so a discarded instance leaves nothing behind.
        _window = State(initialValue: WindowModel(app: app, target: target.wrappedValue))
    }

    public var body: some View {
        RootView(window: window)
            .focusedSceneValue(\.window, window)
            .onAppear {
                let restored = storedShowInspector.map { ($0, storedInspectorPane ?? .tasks) }
                window.start(inspector: restored)
                // Kept from the start, so a window never restores another window's inspector.
                storedShowInspector = window.showInspector
                storedInspectorPane = window.inspectorPane
            }
            // The window's own, so Edit ▸ Undo takes back an archive, a pin or a rename made in it.
            .onChange(of: undoManager, initial: true) { window.undoManager = undoManager }
            .onChange(of: window.hostID) { target = window.target(keeping: target.id) }
            .onChange(of: window.threadID) { target = window.target(keeping: target.id) }
            // Not initial: `start()` reads the stored values first.
            .onChange(of: window.showInspector) { storedShowInspector = window.showInspector }
            .onChange(of: window.inspectorPane) { storedInspectorPane = window.inspectorPane }
            // A chat's link: this window if it shows the chat, else any. New Chat's link always
            // opens a window of its own, so it never takes over the chat or draft of one in use.
            .handlesExternalEvents(preferring: TetherLink.preference(host: window.hostID, thread: window.threadID),
                                   allowing: [TetherLink.chatPrefix])
            .onOpenURL { url in
                guard let link = TetherLink(url) else { return }
                Task { await window.handle(link) }
            }
            .onDisappear { window.close() }
            .onChange(of: appearsActive, initial: true) { window.isKey = appearsActive }
    }
}

public struct RootView: View {
    let window: WindowModel

    public init(window: WindowModel) {
        self.window = window
    }

    private var app: AppModel { window.app }

    public var body: some View {
        splitView
        // Reaches the inspector too, whose task list shows subagents the same way.
        .environment(\.inspectSubagent, InspectSubagentAction(window: window))
        .environment(\.restoreCode, RestoreCodeAction(window: window))
        .environment(\.startSuggestedTask, StartSuggestedTaskAction(window: window))
        .environment(\.openChat, OpenChatAction(window: window))
        .environment(\.forkChat, ForkChatAction(window: window))
        .environment(\.hostIsLocal, window.connection?.host.isLocal == true)
        .environment(\.transcriptFind, window.find)
        .environment(\.promptNavigator, window.prompts)
        .environment(\.composerDrafts, ComposerDrafts(app: app))
        .chatActionAlerts(window)
        .task { app.connectAll() }
    }

    private var splitView: some View {
        // No columnVisibility binding: writing it on every sidebar toggle rebuilt the toolbar mid-animation.
        NavigationSplitView {
            SidebarView(window: window)
                // A flexible frame reports a minimum of 0 whatever its child wants, so the column's
                // minimum comes only from the declared widths: a content-derived one that moved during
                // constraint updates looped AppKit's Update Constraints when the window narrowed.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailView(window: window)
                // A flexible frame reports a minimum of 0 whatever its child wants, so the column's
                // minimum comes only from the declared widths: a content-derived one that moved during
                // constraint updates looped AppKit's Update Constraints when the window narrowed.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                // Title, subtitle and toolbar belong to the container, not to whichever screen is inside it:
                // every item is then declared once and unconditionally, so nothing moves on selection.
                .navigationTitle(window.title)
                .navigationSubtitle(window.subtitle)
                // Not identified, and so not customizable: an identified toolbar is one AppKit keeps
                // in step across every window, removing an item from all of them at once by its
                // index, and two windows' items differ for a moment (one going to New Chat, one
                // inspector open): the other window had no item at that index and AppKit threw
                // (`-[NSToolbar _itemAtIndex:]`, `_currentItems`).
                .toolbar {
                    ToolbarItem(placement: .navigation) { NewChatButton(window: window) }
                        .visibilityPriority(.high)
                    // The last to go to the » menu when the window is narrow; the title gives way first.
                    ToolbarItem(placement: .primaryAction) {
                        ToolbarSessionControl(window: window, control: SessionMenus.init(settings:))
                    }
                    .visibilityPriority(ToolbarItemVisibilityPriority(higherThan: .high))
                    // Keeps the chat's settings apart from the inspector button beside them.
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
        }
        // Attached to the split view, so it is full height and present on every screen.
        .modifier(InspectorColumn(window: window))
    }
}

/// SwiftUI's inspector on the split view, full height, with its button in its own toolbar over
/// the column, so it never tints. The pane tabs are in the pane, not the toolbar: there, every
/// change of tab made AppKit lay the whole toolbar out again.
private struct InspectorColumn: ViewModifier {
    @Bindable var window: WindowModel

    func body(content: Content) -> some View {
        content.inspector(isPresented: $window.showInspector) {
            InspectorView(window: window, selectedTaskID: $window.inspectedTaskID)
                // A flexible frame reports a minimum of 0 whatever its child wants, so the column's
                // minimum comes only from the declared widths: a content-derived one that moved during
                // constraint updates looped AppKit's Update Constraints when the window narrowed.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                // Resizable. Dragging the column wider once crashed SwiftUI's split view (#83, an
                // Apple bug); re-check that on each macOS build.
                .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem { InspectorToggle(window: window) }
                }
        }
    }
}

/// The selected chat, or the New Chat screen. One container, so the detail column is never torn down.
struct DetailView: View {
    let window: WindowModel

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
        .environment(\.messageSendGeometry, window.sendGeometry)
    }
}

struct NewChatButton: View {
    let window: WindowModel

    var body: some View {
        // Titled, for VoiceOver and the » menu.
        Button("New Chat", systemImage: "square.and.pencil") { window.newChat() }
            .help("New Chat")
    }
}

/// File ▸ New Chat and New Window. New Chat acts on the frontmost window, opening one if there is
/// none; the first window opened this launch shows the last chat, and later ones New Chat.
public struct FileCommands: View {
    let app: AppModel
    @FocusedValue(\.window) private var window
    @Environment(\.openWindow) private var openWindow

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Button("New Chat") {
            if let window { window.newChat() } else { openWindow(value: app.newWindowTarget()) }
        }
        .keyboardShortcut("n")
        Button("New Window") { openWindow(value: app.newWindowTarget()) }
            .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

/// Edit ▸ Find, for the frontmost window's chat: Find… opens the bar over the transcript, and Find
/// Next and Previous step through what it matched, dimmed on New Chat, where there's nothing to
/// find; and Search Chats, the sidebar's field.
public struct FindCommands: View {
    @FocusedValue(\.window) private var window

    public init() {}

    public var body: some View {
        let find = window?.selectedThread == nil ? nil : window?.find
        Menu("Find") {
            Group {
                Button("Find…") { find?.show() }
                    .keyboardShortcut("f")
                Button("Find Next") { if find?.isPresented == true { find?.next() } else { find?.show() } }
                    .keyboardShortcut("g")
                Button("Find Previous") { if find?.isPresented == true { find?.previous() } else { find?.show() } }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(find == nil)
            Divider()
            // The sidebar's search field, as Mail's Mailbox Search is ⌥⌘F.
            Button("Search Chats") { window?.searchingChats = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(window == nil)
        }
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
    let app: AppModel

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
        // One of the panes, checked only while it's showing. Choosing one (or its shortcut) always
        // shows it, opening the inspector if needed; ⌥⌘I hides it.
        Picker("Inspector", selection: Binding(get: { window?.showInspector == true ? window?.inspectorPane : nil },
                                               set: { if let pane = $0 { window?.openInspector(on: pane) } })) {
            ForEach(InspectorPane.allCases) { pane in
                Text(pane.label)
                    .tag(Optional(pane))
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
/// RootView as its scene shows it, with the app-wide values the scene sets.
private struct RootPreview: View {
    let window: WindowModel
    var body: some View { RootView(window: window).appEnvironment(window.app) }
}

// #Preview bodies are result-builder closures (no `if`/control flow), so the selection is set here.
@MainActor
private func rootPreviewWindow() -> WindowModel {
    let app = AppModel.sample()
    return .sample(app, threadID: app.connection(app.lastHostID)?.chats.first?.id)
}

#Preview("RootView") {
    RootPreview(window: rootPreviewWindow())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (default new chat)") {
    RootPreview(window: .sample())
        .frame(width: 1100, height: 760)
}

#Preview("RootView (inspector open)") {
    let window = rootPreviewWindow()
    window.openInspector(on: .tasks)
    return RootPreview(window: window)
        .frame(width: 1160, height: 760)
}

#Preview("RootView (wide transcript)") {
    let window = rootPreviewWindow()
    window.app.transcriptWidth = .wide
    return RootPreview(window: window)
        .frame(width: 1400, height: 760)
}

#Preview("RootView (bigger text)") {
    let window = rootPreviewWindow()
    window.app.textScale = 1.5
    return RootPreview(window: window)
        .frame(width: 1100, height: 760)
}

// The narrowest window without the inspector: every toolbar item must still fit.
#Preview("RootView (narrow window)") {
    RootPreview(window: rootPreviewWindow())
        .frame(width: 800, height: 600)
}

#endif
