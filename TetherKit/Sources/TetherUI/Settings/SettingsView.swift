import SwiftUI
import TetherKit

/// Settings areas are selected from the sidebar; host management stays in its own pane.
public struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage("tether.settingsPane") private var storedSelection = SettingsDestination.general.storedValue

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsDestination.general)
                Label("Hosts", systemImage: "network")
                    .tag(SettingsDestination.hosts)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                switch SettingsDestination(storedValue: storedSelection) {
                case .general: GeneralSettings(app: app)
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
/// has ("chats", "newChats", "host:<uuid>"); each one lands on the pane that absorbed it.
enum SettingsDestination: Hashable {
    case general
    case hosts

    init(storedValue: String) {
        switch storedValue {
        case "hosts": self = .hosts
        default: self = storedValue.hasPrefix("host:") ? .hosts : .general
        }
    }

    var storedValue: String {
        switch self {
        case .general: "general"
        case .hosts: "hosts"
        }
    }

    var title: String {
        switch self {
        case .general: "General"
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
    defaults.set("hosts", forKey: "tether.settingsPane")
    return SettingsView(app: .sample(connections: [.sample(), ssh]))
        .defaultAppStorage(defaults)
}
#endif
