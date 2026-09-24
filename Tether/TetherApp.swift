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
        #endif
        return AppModel()
    }()

    var body: some Scene {
        WindowGroup("Tether") {
            RootView(app: app)
                // The inspector adds a column; the window must grow with its minimum width.
                .frame(minWidth: app.showInspector ? 1160 : 900, minHeight: 600)
                .onAppear {
                    #if DEBUG
                    // Debug: launch with TETHER_OPEN_THREAD=<id> to open a chat directly.
                    if let id = ProcessInfo.processInfo.environment["TETHER_OPEN_THREAD"] {
                        app.open(threadID: id, on: HostConfig.local.id)
                    }
                    #endif
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { app.newChat() }.keyboardShortcut("n")
            }
            // Also in the View menu, so changing it doesn't mean opening Settings.
            CommandGroup(after: .toolbar) {
                TranscriptWidthCommands(app: app)
                ShellViewCommands(app: app)
            }
            CommandMenu("Host") { HostCommands(app: app) }
            CommandMenu("Chat") { ChatCommands(app: app) }
            // View ▸ Show Sidebar, for the toolbar's sidebar button.
            SidebarCommands()
            // View ▸ Show Toolbar / Customize Toolbar…, for the identified toolbar in RootView.
            ToolbarCommands()
        }
        // The Settings view supplies the split window's minimum size.
        Settings { SettingsView(app: app) }
    }
}
