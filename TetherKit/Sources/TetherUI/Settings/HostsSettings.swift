import SwiftUI
import TetherKit

/// The hosts Tether can run Claude Code on: a source list with the usual add/remove bar, and the
/// selected host's settings beside it. Everything here applies as it is edited.
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
        HStack(spacing: 0) {
            hostList
                .frame(width: 208)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 470)
        // Opens on the host the window is showing. Set once the list exists rather than in `init`:
        // a selection arriving with the list's first layout is one the list has nowhere to put.
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

    private var hostList: some View {
        // Read once, outside the rows: the list builds those lazily, and an observable read from
        // inside one lands in the middle of its own diff.
        let states = Dictionary(uniqueKeysWithValues:
            app.hosts.map { ($0.id, app.connection($0.id)?.state ?? .disconnected) })
        return VStack(spacing: 0) {
            // Rows are identified by `HostConfig.id`, which is what `selection` holds.
            List(app.hosts, selection: $selection) { host in
                let state = states[host.id] ?? .disconnected
                HStack(spacing: 8) {
                    Image(systemName: host.isLocal ? "laptopcomputer" : "network")
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.name).lineLimit(1)
                        // Only when it adds something: not "This Mac" under "This Mac", nor an alias under itself.
                        if let destination = host.sshDestination, destination != host.name {
                            Text(destination)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    // A symbol, never colour alone, and no spinner: a row that animates while a
                    // host reconnects would pull the eye across the window.
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.tint)
                        .help(state.help)
                        .accessibilityLabel(state.help)
                }
            }
            .listStyle(.inset)
            listButtons
        }
    }

    /// The standard bar under a source list: add on the left, remove next to it.
    private var listButtons: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button { addingHost = true } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .accessibilityLabel("Add SSH Host")
                    .help("Add SSH Host")
                Button { hostToRemove = removableHost } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(removableHost == nil)
                    .accessibilityLabel("Remove Host")
                    .help("Remove Host")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
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
