import Foundation
import Network

/// How long a lost connection waits before trying again. Quick at first, since a daemon restart or
/// a blip is over in seconds; then less and less often, since a host that stays away (asleep, off
/// the network, powered down) cost an SSH attempt every 30 s for as long as the app was open.
/// The network coming back, the Mac waking and Reconnect start it over (`HostConnection.retryNow`).
public enum ReconnectBackoff {
    /// 2, 4, 8 and 16 s; then 30 s for four tries; then 5 minutes for four; then 15 minutes.
    static func base(afterFailures failures: Int) -> Double {
        switch failures {
        case ..<1: 0
        case 1...4: pow(2, Double(failures))
        case 5...8: 30
        case 9...12: 5 * 60
        default: 15 * 60
        }
    }

    /// The wait after `failures` attempts in a row, spread by up to a fifth either way (`jitter` is
    /// in 0..<1), so hosts that dropped together don't all try again together.
    public static func delay(afterFailures failures: Int, jitter: Double) -> Duration {
        let spread = 0.8 + 0.4 * min(max(jitter, 0), 1)
        return .milliseconds(Int((base(afterFailures: failures) * spread * 1000).rounded()))
    }
}

/// Whether this Mac can reach the network, from `NWPathMonitor`. A host over SSH isn't tried while
/// it can't, and is tried at once when it can again or the path changes (Wi-Fi to Ethernet, a VPN):
/// polling an unreachable host only spent energy.
@MainActor
public final class NetworkPath {
    public static let shared = NetworkPath(monitoring: true)

    /// Whether some interface can reach the network. True until the monitor says otherwise.
    public private(set) var isSatisfied = true
    /// The interfaces the satisfied path goes over, to tell a change of network from a repeat.
    private var interfaces: [String] = []
    private var monitor: NWPathMonitor?
    private let monitoring: Bool
    private var watchers: [Weak] = []

    private struct Weak { weak var connection: HostConnection? }

    /// `monitoring: false` for tests, which say what the path does with `update`.
    init(monitoring: Bool) {
        self.monitoring = monitoring
    }

    /// Tells `connection` when the path comes back or changes. Held weakly.
    func watch(_ connection: HostConnection) {
        watchers.removeAll { $0.connection == nil || $0.connection === connection }
        watchers.append(Weak(connection: connection))
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard monitoring, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let names = path.availableInterfaces.map(\.name)
            Task { @MainActor in NetworkPath.shared.update(satisfied: satisfied, interfaces: names) }
        }
        monitor.start(queue: DispatchQueue(label: "Tether Network Path", qos: .utility))
        self.monitor = monitor
    }

    func update(satisfied: Bool, interfaces: [String] = []) {
        let changed = satisfied != isSatisfied || interfaces != self.interfaces
        isSatisfied = satisfied
        self.interfaces = interfaces
        guard changed, satisfied else { return }
        watchers.removeAll { $0.connection == nil }
        for watcher in watchers { watcher.connection?.networkChanged() }
    }
}
