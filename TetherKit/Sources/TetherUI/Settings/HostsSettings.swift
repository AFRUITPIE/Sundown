import SwiftUI
import TetherKit

/// Host management stays in one Settings pane. A picker chooses which host's form is shown.
struct HostsSettings: View {
    @Bindable var app: AppModel
    @State private var selection: UUID?
    @State private var addingHost = false
    @State private var hostToRemove: HostConfig?

    private var selectedHost: HostConfig? {
        app.hosts.first { $0.id == selection } ?? app.hosts.first
    }

    /// This Mac is how Tether talks to itself; only an SSH host can be removed.
    private var removableHost: HostConfig? {
        selectedHost.flatMap { $0.isLocal ? nil : $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            hostPicker
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if selection == nil { selection = app.hostID } }
        .sheet(isPresented: $addingHost) {
            AddSSHHostSheet { host in
                app.addHost(host)
                selection = host.id
            }
        }
        .alert("Remove “\(hostToRemove?.name ?? "")”?", isPresented: Binding(
            get: { hostToRemove != nil },
            set: { if !$0 { hostToRemove = nil } }
        ), presenting: hostToRemove) { host in
            Button("Remove", role: .destructive) {
                app.removeHost(host.id)
                selection = HostConfig.local.id
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Chats and configuration on the host itself are unchanged.")
        }
    }

    private var hostPicker: some View {
        HStack(spacing: 12) {
            Picker("Host", selection: hostSelection) {
                ForEach(app.hosts) { host in
                    Label(host.name, systemImage: host.symbol)
                        .tag(host.id)
                }
            }
            .pickerStyle(.menu)
            Spacer(minLength: 12)

            Button {
                addingHost = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add SSH Host")
            .help("Add SSH Host")

            Button {
                hostToRemove = removableHost
            } label: {
                Image(systemName: "minus")
            }
            .disabled(removableHost == nil)
            .accessibilityLabel("Remove Host")
            .help("Remove Host")
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hostSelection: Binding<UUID> {
        Binding(
            get: { selectedHost?.id ?? HostConfig.local.id },
            set: { selection = $0 }
        )
    }

    @ViewBuilder private var detail: some View {
        if let host = selectedHost {
            HostDetail(host: host, connection: app.connection(host.id)) { app.updateHost($0) }
                // A different host gets its own fields, so a part-typed name can't land on it.
                .id(host.id)
        } else {
            ContentUnavailableView("No Hosts", systemImage: "network")
        }
    }
}

/// A connection state as a symbol and a word. Never colour on its own: with the colour off the
/// symbol still says which state this is.
struct HostStatusLabel: View {
    let state: HostConnection.State

    var body: some View {
        HStack(spacing: 6) {
            if case .connecting = state {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            Text(state.detailLabel)
        }
        .help(state.help)
        .accessibilityLabel(state.help)
    }
}

extension HostConnection.State {
    /// The same words the sidebar uses for these states, so one host never reads two ways.
    var label: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .failed, .disconnected: "Not Connected"
        }
    }

    /// While connecting, the daemon's own progress message ("Handshaking…") says more than the word.
    var detailLabel: String {
        if case .connecting(let message) = self { return message }
        return label
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting: "ellipsis.circle"
        case .failed: "exclamationmark.triangle"
        case .disconnected: "bolt.horizontal.circle"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .failed: .orange
        default: .secondary
        }
    }

    /// Why the last attempt failed — the only part of a state the user can act on.
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var help: String {
        failureMessage.map { "Not Connected: \($0)" } ?? detailLabel
    }
}

#if DEBUG
#Preview("Hosts (this Mac only)") {
    HostsSettings(app: .sample())
}

#Preview("Hosts (connected SSH host)") {
    let ssh = HostConnection.sampleConnectedSSH()
    let app = AppModel.sample(connections: [.sample(), ssh])
    app.hostID = ssh.id
    return HostsSettings(app: app)
}

#Preview("Hosts (connection failed)") {
    let failed = HostConnection.sampleFailed()
    let app = AppModel.sample(connections: [.sample(), failed])
    app.hostID = failed.id
    return HostsSettings(app: app)
}

#Preview("Hosts (connecting)") {
    let connecting = HostConnection.sampleConnecting()
    let app = AppModel.sample(connections: [.sample(), connecting])
    app.hostID = connecting.id
    return HostsSettings(app: app)
}
#endif
