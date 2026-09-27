import SwiftUI
import TetherKit

/// The Host menu in the menu bar: which host the sidebar lists and a new chat starts on, and its
/// connection. Not a toolbar control: it changes only when switching sessions, which is the
/// sidebar's job, and the subtitle names the host whenever there is more than one.
public struct HostCommands: View {
    let app: AppModel
    @FocusedValue(\.window) private var window
    @Environment(\.openSettings) private var openSettings
    @AppStorage("tether.settingsPane") private var settingsPane = SettingsDestination.general.storedValue

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        // The frontmost window's host; with no window open the hosts are listed, dimmed.
        if let window {
            HostPicker(window: window)
                .pickerStyle(.inline)
        } else {
            Picker("Host", selection: .constant(app.lastHostID)) {
                ForEach(app.hosts) { host in Label(host.name, systemImage: host.symbol).tag(host.id) }
            }
            .pickerStyle(.inline)
            .disabled(true)
        }
        Divider()
        if let connection = window?.connection ?? app.connection(app.lastHostID) {
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
    @Bindable var window: WindowModel

    var body: some View {
        Picker("Host", selection: $window.hostID) {
            ForEach(window.app.hosts) { host in
                Label(host.name, systemImage: host.symbol).tag(host.id)
            }
        }
    }
}
