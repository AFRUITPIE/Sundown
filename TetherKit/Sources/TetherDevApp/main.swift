import SwiftUI
import TetherUI

/// Development runner (`swift run TetherDevApp`). The shipping app is the Xcode target.
@main
struct TetherDevApp: App {
    @State private var app = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Tether") {
            RootView(app: app)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { NSApplication.shared.activate() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { app.newChat() }.keyboardShortcut("n")
            }
        }
        Settings { SettingsView(app: app) }
    }
}
