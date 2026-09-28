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
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The host's form scrolls under the picker, with the system's edge effect.
            .safeAreaBar(edge: .top) { hostPicker }
        .task { if selection == nil { selection = app.lastHostID } }
        .sheet(isPresented: $addingHost) {
            AddSSHHostSheet { host in
                app.addHost(host)
                selection = host.id
            }
        }
        .confirmationDialog("Remove “\(hostToRemove?.name ?? "")”?", isPresented: Binding(
            get: { hostToRemove != nil },
            set: { if !$0 { hostToRemove = nil } }
        ), titleVisibility: .visible, presenting: hostToRemove) { host in
            Button("Remove", role: .destructive) {
                app.removeHost(host.id)
                selection = HostConfig.local.id
            }
        } message: { _ in
            Text("Its chats stay on the host.")
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

            // The add/remove pair: one control, so the thinner minus glyph gets the plus's height.
            ControlGroup {
                Button("Add SSH Host", systemImage: "plus") { addingHost = true }
                    .help("Add SSH Host")
                Button("Remove Host", systemImage: "minus") { hostToRemove = removableHost }
                    .disabled(removableHost == nil)
                    .help("Remove Host")
            }
            .labelStyle(.iconOnly)
        }
        .padding()
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
        Label {
            Text(state.detailLabel)
        } icon: {
            if case .connecting = state {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
        }
        .labelStyle(.titleAndIcon)
        .help(state.help)
        // Read as it's written ("Connected"); the help says more for the pointer.
        .accessibilityElement(children: .combine)
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
    // First, so Settings opens on it.
    return HostsSettings(app: .sample(connections: [ssh, .sample()]))
}

#Preview("Hosts (connection failed)") {
    let failed = HostConnection.sampleFailed()
    // First, so Settings opens on it.
    return HostsSettings(app: .sample(connections: [failed, .sample()]))
}

#Preview("Hosts (connecting)") {
    let connecting = HostConnection.sampleConnecting()
    // First, so Settings opens on it.
    return HostsSettings(app: .sample(connections: [connecting, .sample()]))
}
#endif
