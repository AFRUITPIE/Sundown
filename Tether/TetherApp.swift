import SwiftUI
import TetherKit
import TetherUI

@main
struct TetherApp: App {
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
        // The Settings view supplies the split window's minimum size.
        Settings { SettingsView(app: app) }
    }
}
