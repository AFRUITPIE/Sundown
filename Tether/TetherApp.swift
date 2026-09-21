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
                        app.selection = .thread(host: HostConfig.local.id, id: id)
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
            }
        }
        Settings { SettingsView(app: app) }
            .defaultSize(width: 660, height: 400)
    }
}
