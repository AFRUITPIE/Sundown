import SwiftUI
import TetherKit

/// The Host menu in the menu bar: which host the sidebar lists and a new chat starts on, and its
/// connection. Not a toolbar control: it changes only when switching sessions, which is the
/// sidebar's job, and the subtitle names the host whenever there is more than one.
public struct HostCommands: View {
    @Bindable var app: AppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("tether.settingsPane") private var settingsPane = SettingsDestination.general.storedValue

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        HostPicker(app: app)
            .pickerStyle(.inline)
        Divider()
        if let connection = app.connection {
            ConnectButton(connection: connection)
        }
        Button("Manage Hosts…") {
            settingsPane = SettingsDestination.hosts.storedValue
            openSettings()
        }
    }
}

/// Connect, or Reconnect once connected. Shared by the Host menu, the sidebar's context menu and
/// Settings ▸ Hosts.
struct ConnectButton: View {
    let connection: HostConnection

    var body: some View {
        Button(connection.state == .connected ? "Reconnect" : "Connect") {
            Task {
                if connection.state == .connected { await connection.reconnect() }
                else { await connection.connect() }
            }
        }
        .disabled(connection.state.isConnecting)
    }
}

/// Every configured host, checked on the current one.
struct HostPicker: View {
    @Bindable var app: AppModel

    var body: some View {
        Picker("Host", selection: $app.hostID) {
            ForEach(app.hosts) { host in
                Label(host.name, systemImage: host.symbol).tag(host.id)
            }
        }
    }
}
