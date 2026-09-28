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
                        Link("Open System Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            .buttonStyle(.bordered)
                    } label: {
                        Text("Notifications Are Off for Tether")
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
            }
            Section("Dock") {
                Picker("Badge Shows", selection: $app.alerts.dockBadge) {
                    ForEach(AlertPreferences.DockBadge.allCases) { Text($0.label).tag($0) }
                }
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
