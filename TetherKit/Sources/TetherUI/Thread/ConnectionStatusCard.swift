import SwiftUI
import TetherKit

/// Why a message can't be sent, in the composer's place while its host isn't connected: a title,
/// one line saying which host or what went wrong, and the fix. A control card, so glass, with a
/// standard bordered button inside. The composer stays mounted behind it, so the draft is kept.
struct ConnectionStatusCard: View {
    let status: Status
    let connection: HostConnection
    /// The install or update being asked about.
    @State private var asking: ServerOffer?

    /// What the card says: nothing while the host is connected.
    enum Status: Equatable {
        case notConnected(host: String)
        case connecting(host: String)
        case failed(reason: String)
        /// No server on the host, or one too old: installed or updated when the user says so.
        case needsServer(ServerOffer, host: String)
        case appTooOld(host: String, serverVersion: String)

        init?(_ state: HostConnection.State, host: String) {
            switch state {
            case .connected: return nil
            case .disconnected: self = .notConnected(host: host)
            case .connecting: self = .connecting(host: host)
            case .failed(let reason): self = .failed(reason: reason)
            case .needsServer(let offer): self = .needsServer(offer, host: host)
            case .appTooOld(let version): self = .appTooOld(host: host, serverVersion: version)
            }
        }

        var title: String {
            switch self {
            case .notConnected: "Not Connected"
            case .connecting: "Connecting…"
            case .failed: "Couldn’t Connect"
            case .needsServer(let offer, _) where offer.failure != nil:
                offer.isUpdate ? "Couldn’t Update Tether" : "Couldn’t Install Tether"
            case .needsServer(let offer, _): offer.isUpdate ? "Tether Needs an Update" : "Tether Isn’t Installed"
            case .appTooOld: "Couldn’t Connect"
            }
        }

        var detail: String {
            switch self {
            case .notConnected(let host), .connecting(let host): host
            case .failed(let reason): reason
            case .needsServer(let offer, _) where offer.failure != nil: offer.failure ?? ""
            case .needsServer(let offer, let host):
                if case .outdated(let installed) = offer.reason {
                    "\(host) runs Tether \(installed); this app needs \(offer.version)."
                } else {
                    host
                }
            case .appTooOld(let host, let version): "\(host) runs Tether \(version), which needs a newer version of this app."
            }
        }

        /// The fix's title; none while connecting.
        var action: String? {
            switch self {
            case .notConnected: "Connect"
            case .connecting: nil
            case .failed, .appTooOld: "Reconnect"
            case .needsServer(let offer, _): offer.askTitle
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).fontWeight(.semibold)
                Text(status.detail)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(status.detail)
            }
            Spacer(minLength: 8)
            if let action = status.action {
                Button(action, action: fix)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("composer.reconnect")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Layout.cardCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.status")
        .serverInstallSheet($asking, connection: connection)
    }

    private func fix() {
        switch status {
        case .needsServer(let offer, _): asking = offer
        case .notConnected: Task { await connection.connect() }
        default: Task { await connection.reconnect() }
        }
    }
}

#if DEBUG
/// A host without the Tether server, or with one too old or too new for this app, or whose install
/// failed: each asks before anything is installed, and says what to do.
#Preview("Status card (server)") {
    VStack(spacing: 24) {
        ForEach([HostConnection.sampleNeedsServer(), .sampleNeedsServer(.outdated(installed: "0.4.0")),
                 .sampleNeedsServer(failure: "Couldn’t download tether-0.5.6-linux-x64 (404)."), .sampleAppTooOld()], id: \.id) { connection in
            BottomBar(thread: .sampleIdleChat(), connection: connection)
        }
    }
    .frame(width: 720)
    .padding(.vertical, 20)
}

/// Each state in a chat's bottom bar, where the composer's field goes: not connected, connecting,
/// and a failure's reason. The composer is still there behind each, with its draft.
#Preview("Status card") {
    VStack(spacing: 24) {
        ForEach([HostConnection.sampleDisconnected(), .sampleConnecting(), .sampleFailed()], id: \.id) { connection in
            BottomBar(thread: .sampleIdleChat(), connection: connection)
        }
    }
    .environment(\.composerDraft, "…and once that's done, run the package tests")
    .frame(width: 720)
    .padding(.vertical, 20)
}

/// A long failure, in the narrowest detail column: the reason wraps to a second line and stops.
#Preview("Status card (long reason, narrow)") {
    let connection = HostConnection.sampleFailed(reason: "ssh: connect to host staging.internal.example.com port 22: Operation timed out after 30 seconds")
    return BottomBar(thread: .sampleIdleChat(), connection: connection)
        .frame(width: 520)
        .padding(.vertical, 20)
}

/// A chat whose transcript never arrived because its host is down: the card says so once, and
/// the transcript above it stays empty rather than saying it again.
#Preview("Status card (chat not loaded)") {
    NavigationStack {
        ThreadView(thread: .sampleUnloaded(), connection: .sampleFailed())
    }
    .frame(width: 900, height: 500)
}
#endif
