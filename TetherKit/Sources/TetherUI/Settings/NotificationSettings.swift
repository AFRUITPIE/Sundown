import AppKit
import SwiftUI

/// Settings ▸ Notifications: when Tether tells you a chat needs you, and what the Dock shows.
struct NotificationSettings: View {
    @Bindable var app: AppModel
    @State private var systemDenied = false

    var body: some View {
        Form {
            if systemDenied {
                Section {
                    LabeledContent {
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } label: {
                        Text("Notifications Are Off for Tether")
                        Text("Turn them on in System Settings to hear from your chats.")
                    }
                }
            }
            Section {
                Picker("Notify When a Reply Finishes", selection: $app.alerts.replyFinished) {
                    ForEach(AlertPreferences.When.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Notify When Claude Needs Your Input", isOn: $app.alerts.needsInput)
                Toggle("Play a Sound", isOn: $app.alerts.sound)
            } header: {
                Text("Notifications")
            } footer: {
                Text("A permission request’s notification has Allow and Deny, so it can be answered without switching.")
            }
            Section("Dock and Menu Bar") {
                Picker("Badge Shows", selection: $app.alerts.dockBadge) {
                    ForEach(AlertPreferences.DockBadge.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show Chats in the Menu Bar", isOn: $app.alerts.menuBarExtra)
            }
        }
        .formStyle(.grouped)
        .task { systemDenied = await app.attention?.systemDenied() ?? false }
    }
}

#if DEBUG
#Preview("Notifications") {
    NotificationSettings(app: .sample())
        .frame(width: 560, height: 420)
}
#endif
