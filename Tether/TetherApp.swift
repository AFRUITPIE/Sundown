import SwiftUI
import TetherKit
import TetherUI

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(TetherAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    /// Active while any of the app's windows is.
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel = {
        // UI tests, in any build: the performance tests run against Release.
        if ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1" {
            return AppModel.uiTestFixture()
        }
        let app = AppModel()
        #if DEBUG
        // Debug: launch with TETHER_OPEN_THREAD=<id> to open a chat directly.
        if let id = ProcessInfo.processInfo.environment["TETHER_OPEN_THREAD"] {
            app.openOnLaunch(threadID: id, on: HostConfig.local.id)
        }
        #endif
        return app
    }()

    var body: some Scene {
        // Before any window: a launch that restores none still gets one (`TetherAppDelegate`).
        let _ = delegate.install(app: app) { openWindow(value: $0) }
        // Each window has its own host and chat. One opened by File ▸ New Window or Open in New
        // Window carries its target.
        WindowGroup(for: WindowTarget.self) { $target in
            WindowRoot(app: app, target: $target)
                .onAppear {
                    app.startAttention()
                    // The app's own actions, which outlive any one window.
                    app.openWindow = { openWindow(value: $0) }
                    app.openURL = { openURL($0) }
                }
        } defaultValue: {
            app.newWindowTarget()
        }
        // Links from outside a window (notifications, the Dock menu, Shortcuts): each window says
        // which it prefers (`WindowRoot`), and one opens when none is open.
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1100, height: 760)
        .appEnvironment(app)
        // The system restores each window to what it showed (its value and scene storage), as
        // the person's "close windows when quitting" setting says; with nothing to restore, a window.
        .defaultLaunchBehavior(.presented)
        .onChange(of: scenePhase, initial: true) { app.isActive = scenePhase == .active }
        .commands {
            // New Chat and New Window: SwiftUI's own New Window kept ⌘N, whatever the scene's
            // `keyboardShortcut` asked for, and ⌘N is New Chat.
            CommandGroup(replacing: .newItem) { FileCommands(app: app) }
            CommandGroup(replacing: .help) { HelpCommands() }
            // Edit ▸ Find, for the chat, where the text-editing commands go. Not `TextEditingCommands`:
            // its Find can't be left out, and a second Find submenu beside the chat's is worse than
            // Spelling and Substitutions only in the message field's own context menu.
            CommandGroup(replacing: .textEditing) { FindCommands() }
            // Also in the View menu, so changing it doesn't mean opening Settings.
            CommandGroup(after: .toolbar) {
                TextSizeCommands(app: app)
                Divider()
                TranscriptWidthCommands(app: app)
                ShellViewCommands(app: app)
            }
            CommandMenu("Host") { HostCommands(app: app) }
            CommandMenu("Chat") { ChatCommands() }
            // View ▸ Show Sidebar, for the toolbar's sidebar button.
            SidebarCommands()
            // View ▸ Show Toolbar / Customize Toolbar…, for the identified toolbar in RootView.
            ToolbarCommands()
        }
        HostWindows(app: app)
            .appEnvironment(app)
        // The Settings view supplies the split window's minimum size.
        Settings { SettingsView(app: app) }
        // No menu bar extra: declared at all, even hidden, it kept SwiftUI updating its label in a
        // loop from launch.
    }
}

/// The windows a host opens from the Host menu. A scene of their own: in `TetherApp.body` itself
/// the scene type nested deeply enough that resolving it at launch overflowed the main thread's stack.
private struct HostWindows: Scene {
    let app: AppModel

    var body: some Scene {
        // A host's Claude Code plugins.
        WindowGroup("Plugins", id: PluginsWindow.id, for: UUID.self) { $hostID in
            PluginsWindow(app: app, hostID: hostID)
        }
        .defaultSize(width: 640, height: 520)
        .handlesExternalEvents(matching: [])
        // Opened for a host from the Host menu, never from File ▸ New.
        .commandsRemoved()
        // A host's scheduled tasks, run by its daemon.
        WindowGroup("Scheduled Tasks", id: ScheduledTasksWindow.id, for: UUID.self) { $hostID in
            ScheduledTasksWindow(app: app, hostID: hostID)
        }
        .defaultSize(width: 820, height: 560)
        .handlesExternalEvents(matching: [])
        // Opened for a host from the Host menu, never from File ▸ New.
        .commandsRemoved()
        // Settings ▸ Advanced ▸ Inspector ▸ Floating Panel: one panel for the front window's chat.
        // Its View-menu item is the app's own Show Inspector, so the scene's is removed.
        UtilityWindow("Inspector", id: InspectorPanel.id) {
            InspectorPanel(app: app)
        }
        .defaultSize(width: 320, height: 560)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        // One per host, kept open beside a chat to follow a reconnect.
        WindowGroup("Connection Log", id: ConnectionLogWindow.id, for: UUID.self) { $hostID in
            ConnectionLogWindow(app: app, hostID: hostID)
        }
        .defaultSize(width: 620, height: 400)
        .handlesExternalEvents(matching: [])
        // Opened for a host from the Host menu, never from File ▸ New.
        .commandsRemoved()
    }
}
