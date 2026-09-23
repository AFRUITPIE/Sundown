import SwiftUI
import TetherKit
import TetherUI

@main
struct TetherApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Tether") {
            RootView(app: app)
                .frame(minWidth: 900, minHeight: 600)
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
            // View ▸ Show Toolbar / Customize Toolbar…, for the identified toolbar in RootView.
            ToolbarCommands()
        }
        // The Settings view supplies the split window's minimum size.
        Settings { SettingsView(app: app) }
    }
}
