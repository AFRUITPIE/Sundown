import SwiftUI
import TetherKit

/// Why a message can't be sent, in the composer's place while its host isn't connected: a title,
/// one line saying which host or what went wrong, and the fix. A control card, so glass, with a
/// standard bordered button inside. The composer stays mounted behind it, so the draft is kept.
struct ConnectionStatusCard: View {
    let status: Status
    let connection: HostConnection

    /// What the card says: nothing while the host is connected.
    enum Status: Equatable {
        case notConnected(host: String)
        case connecting(host: String)
        case failed(reason: String)
        /// No Node.js 18 or later on the host: the user installs it, or has this Mac install the
        /// server there.
        case needsNode(NodeNeeded, host: String)

        init?(_ state: HostConnection.State, host: String) {
            switch state {
            case .connected: return nil
            case .disconnected: self = .notConnected(host: host)
            case .connecting: self = .connecting(host: host)
            case .failed(let reason): self = .failed(reason: reason)
            case .needsNode(let need): self = .needsNode(need, host: host)
            }
        }

        var title: String {
            switch self {
            case .notConnected: "Not Connected"
            case .connecting: "Connecting…"
            case .failed: "Couldn’t Connect"
            case .needsNode(let need, _): need.title
            }
        }

        var detail: String {
            switch self {
            case .notConnected(let host), .connecting(let host): host
            case .failed(let reason): reason
            case .needsNode(let need, let host): need.detail(host: host)
            }
        }

        /// The fix's title; none while connecting.
        var action: String? {
            switch self {
            case .notConnected: "Connect"
            case .connecting: nil
            case .failed: "Reconnect"
            case .needsNode: "Check Again"
            }
        }

        /// The install offered beside it, when there is one.
        var copy: ServerCopy? {
            if case .needsNode(let need, _) = self { need.copy } else { nil }
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
            if let copy = status.copy, case .needsNode(let need, _) = status {
                Button(need.installTitle) { Task { await connection.copyServer(copy) } }
                    .buttonStyle(.bordered)
                    .disabled(connection.isCopying)
                    .accessibilityIdentifier("composer.installServer")
            }
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
    }

    private func fix() {
        switch status {
        case .notConnected, .needsNode: Task { await connection.connect() }
        default: Task { await connection.reconnect() }
        }
    }
}

extension NodeNeeded {
    /// What a host without a usable Node.js says: the title, and the line under it.
    var title: String { copy?.failure != nil ? "Couldn’t Install Tether" : "Tether Needs Node.js" }

    func detail(host: String) -> String {
        if let failure = copy?.failure { return failure }
        if let found { return "\(host) has Node.js \(found); install \(ServerRelease.minimumNode) or later." }
        return "Install Node.js \(ServerRelease.minimumNode) or later on \(host)."
    }

    /// The button that has this Mac install the server there instead.
    var installTitle: String { copy?.failure != nil ? "Try Again" : "Install Tether" }
}

#if DEBUG
/// A host without Node.js, with one too old, with no build to install, and whose install failed.
#Preview("Status card (Node.js)") {
    VStack(spacing: 24) {
        ForEach([HostConnection.sampleNeedsNode(), .sampleNeedsNode(found: "16.20.2"), .sampleNeedsNode(canCopy: false),
                 .sampleNeedsNode(failure: "Couldn’t download tether-0.5.7-linux-x64 (404).")], id: \.id) { connection in
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
