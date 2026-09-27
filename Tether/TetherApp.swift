import SwiftUI
import TetherKit
import TetherUI

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(TetherAppDelegate.self) private var delegate
    @State private var app: AppModel = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1" {
            return AppModel.uiTestFixture()
        }
        let app = AppModel()
        // Debug: launch with TETHER_OPEN_THREAD=<id> to open a chat directly.
        if let id = ProcessInfo.processInfo.environment["TETHER_OPEN_THREAD"] {
            app.openOnLaunch(threadID: id, on: HostConfig.local.id)
        }
        return app
        #else
        return AppModel()
        #endif
    }()

    var body: some Scene {
        // Each window has its own host and chat. One opened by File ▸ New Window or Open in New
        // Window carries its target; the system restores it with the window.
        WindowGroup("Tether", for: WindowTarget.self) { $target in
            WindowRoot(app: app, target: target)
                .onAppear {
                    delegate.app = app
                    app.startAttention()
                }
        }
        .defaultSize(width: 1100, height: 760)
        // A window at every launch, including after a crash or force quit, which otherwise restored
        // the app with none.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) { FileCommands(app: app) }
            CommandGroup(replacing: .help) { HelpCommands() }
            CommandGroup(after: .pasteboard) {
                Divider()
                FindCommands()
            }
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
        // The Settings view supplies the split window's minimum size.
        Settings { SettingsView(app: app) }
        MenuBarScene(app: app)
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
        // A host's scheduled tasks, run by its daemon.
        WindowGroup("Scheduled Tasks", id: ScheduledTasksWindow.id, for: UUID.self) { $hostID in
            ScheduledTasksWindow(app: app, hostID: hostID)
        }
        .defaultSize(width: 820, height: 560)
        // One per host, kept open beside a chat to follow a reconnect.
        WindowGroup("Connection Log", id: ConnectionLogWindow.id, for: UUID.self) { $hostID in
            ConnectionLogWindow(app: app, hostID: hostID)
        }
        .defaultSize(width: 620, height: 400)
    }
}

/// Chats waiting or working, in the menu bar; off unless Settings ▸ Notifications turns it on.
private struct MenuBarScene: Scene {
    let app: AppModel
    /// Plain defaults, not the app model: see `AlertPreferences.menuBarExtraKey`.
    @AppStorage(AlertPreferences.menuBarExtraKey) private var shown = false

    var body: some Scene {
        MenuBarExtra(isInserted: $shown) {
            MenuBarChats(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.menu)
    }
}
