import SwiftUI
import SundownKit

/// Settings areas are selected from the sidebar; host management stays in its own pane.
public struct SettingsView: View {
    let app: AppModel
    @AppStorage("sundown.settingsPane") private var storedSelection = SettingsDestination.general.storedValue

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsDestination.general)
                Label("Notifications", systemImage: "bell.badge")
                    .tag(SettingsDestination.notifications)
                Label("Hosts", systemImage: "network")
                    .tag(SettingsDestination.hosts)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            // A settings window's sidebar is always shown, as System Settings' is.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch SettingsDestination(storedValue: storedSelection) {
                case .general: GeneralSettings(app: app)
                case .notifications: NotificationSettings(app: app)
                case .hosts: HostsSettings(app: app)
                }
            }
            .navigationTitle(SettingsDestination(storedValue: storedSelection).title)
        }
        .frame(minWidth: 700, minHeight: 470)
    }

    private var selection: Binding<SettingsDestination?> {
        Binding(
            get: { SettingsDestination(storedValue: storedSelection) },
            set: { if let value = $0 { storedSelection = value.storedValue } }
        )
    }
}

/// The selected pane, persisted. Stores written by older builds named panes this window no longer
/// has ("chats", "newChats", "appearance", "host:<uuid>"); each one lands on the pane that absorbed it.
enum SettingsDestination: Hashable {
    case general
    case notifications
    case hosts

    init(storedValue: String) {
        switch storedValue {
        case "hosts": self = .hosts
        case "notifications": self = .notifications
        default: self = storedValue.hasPrefix("host:") ? .hosts : .general
        }
    }

    var storedValue: String {
        switch self {
        case .general: "general"
        case .notifications: "notifications"
        case .hosts: "hosts"
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .hosts: "Hosts"
        }
    }
}

#if DEBUG
#Preview("Settings — General") {
    SettingsView(app: .sample())
}

#Preview("Settings — Hosts") {
    let ssh = HostConnection.sampleConnectedSSH()
    let defaults = UserDefaults(suiteName: "SettingsPreview.Hosts")!
    defaults.set("hosts", forKey: "sundown.settingsPane")
    return SettingsView(app: .sample(connections: [.sample(), ssh]))
        .defaultAppStorage(defaults)
}
#endif
