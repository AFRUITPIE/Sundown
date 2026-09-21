import SwiftUI
import TetherKit

/// Two panes, the way a macOS Settings window is built: what the app does (General) and what it
/// connects to (Hosts). Each pane sizes the window itself; nothing is pinned here.
public struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage("tether.settingsPane") private var storedSelection = SettingsDestination.general.storedValue

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        TabView(selection: selection) {
            Tab("General", systemImage: "gearshape", value: SettingsDestination.general) {
                GeneralSettings(app: app)
            }
            Tab("Hosts", systemImage: "network", value: SettingsDestination.hosts) {
                HostsSettings(app: app)
            }
        }
    }

    private var selection: Binding<SettingsDestination> {
        Binding(
            get: { SettingsDestination(storedValue: storedSelection) },
            set: { storedSelection = $0.storedValue }
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
}

#if DEBUG
#Preview("Settings") {
    SettingsView(app: .sample())
}
#endif
