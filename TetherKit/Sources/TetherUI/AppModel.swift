import Foundation
import Observation
import SwiftUI
import TetherKit
import TetherProtocol

public enum SidebarSelection: Hashable, Sendable {
    case newChat(host: UUID)
    case thread(host: UUID, id: String)

    var hostId: UUID {
        switch self {
        case .newChat(let h), .thread(let h, _): return h
        }
    }
}

/// App-wide state: configured hosts, their live connections, and the sidebar selection.
@MainActor
@Observable
public final class AppModel {
    public private(set) var hosts: [HostConfig] = []
    public private(set) var connections: [UUID: HostConnection] = [:]
    /// Resolving a selection creates the thread's model if it doesn't exist yet, which mutates
    /// observable state — so it happens here, when the selection changes, and never while a view
    /// is rendering (SwiftUI redraws the window when state changes mid-update).
    public var selection: SidebarSelection? { didSet { resolveSelection() } }
    public private(set) var selectedThread: ThreadModel?

    /// Whether the trailing inspector is shown. Lives here (not on ThreadView) so `.inspector`
    /// can wrap the whole NavigationSplitView and span the full window height, like Xcode's
    /// right sidebar, instead of just the detail column.
    public var showInspector: Bool {
        get { access(keyPath: \.showInspector); return inspectorStorage }
        // Guarded the way the @Observable macro guards its own setters: without it, writing the
        // value it already has still notifies every observer. The framework writes this one
        // whenever it restores or collapses the inspector, so the redundant writes are frequent.
        set {
            guard newValue != inspectorStorage else { return }
            withMutation(keyPath: \.showInspector) { inspectorStorage = newValue }
        }
    }
    @ObservationIgnored @AppStorage("tether.inspector") private var inspectorStorage = false

    /// Draft session-control values for the New Chat screen (shown in the window toolbar and
    /// used to start the thread). Not persisted — reset to the app defaults by `newChat()`.
    public var draftModel: String?
    public var draftEffort: EffortLevel?
    public var draftPermissionMode: PermissionMode = .default

    /// How wide the transcript may get (persisted). Narrow by default: capped line length is
    /// easier to read than text that fills a wide window.
    public var transcriptWidth: TranscriptWidth = .narrow { didSet { save() } }

    /// Defaults for new threads, per app (persisted).
    public var defaultModel: String? { didSet { save() } }
    public var defaultEffort: String? { didSet { save() } }
    public var defaultPermissionMode: String = "default" { didSet { save() } }

    private let defaults: UserDefaults
    private static let hostsKey = "tether.hosts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Use the same store as `defaults` (real UserDefaults for the app, an isolated suite for
        // previews) so `.sample()` never reads or writes the real "tether.inspector" value.
        _inspectorStorage = AppStorage(wrappedValue: false, "tether.inspector", store: defaults)
        load()
        for h in hosts { connections[h.id] = HostConnection(host: h) }
        newChat()
    }

    public func connection(_ id: UUID) -> HostConnection? { connections[id] }

    public func connectAll() {
        for c in connections.values { Task { await c.connect() } }
    }

    public func addHost(_ h: HostConfig) {
        hosts.append(h)
        let c = HostConnection(host: h)
        connections[h.id] = c
        save()
        Task { await c.connect() }
    }

    public func updateHost(_ h: HostConfig) {
        guard let i = hosts.firstIndex(where: { $0.id == h.id }) else { return }
        hosts[i] = h
        connections[h.id]?.update(host: h)
        save()
    }

    public func removeHost(_ id: UUID) {
        guard id != HostConfig.local.id else { return }
        hosts.removeAll { $0.id == id }
        if let c = connections.removeValue(forKey: id) { Task { await c.disconnect() } }
        if selection?.hostId == id {
            selection = nil
            newChat()
        }
        save()
    }

    // MARK: selection helpers

    /// Start composing a new chat on the currently selected host (or this Mac).
    public func newChat() {
        let host = selection?.hostId ?? HostConfig.local.id
        selection = .newChat(host: host)
        // A concrete model, not "whatever the CLI decides": nothing in the protocol reports the
        // CLI's own default, so the app's default is the one set in Settings, falling back to the
        // top of that host's catalog until one is chosen.
        draftModel = defaultModel ?? connections[host]?.models.defaultValue
        draftEffort = defaultEffort.map(EffortLevel.init(rawValue:))
        draftPermissionMode = PermissionMode(rawValue: defaultPermissionMode)
    }

    /// Whether a chat is on screen, as opposed to the New Chat screen — the inspector has
    /// nothing to show without one.
    public var isThreadSelected: Bool {
        if case .thread = selection { return true }
        return false
    }

    public var selectedConnection: HostConnection? {
        selection.flatMap { connections[$0.hostId] }
    }

    private func resolveSelection() {
        guard case .thread(let h, let id) = selection, let c = connections[h] else {
            selectedThread = nil
            return
        }
        selectedThread = c.thread(id)
    }

    // MARK: persistence

    private struct Stored: Codable {
        var hosts: [HostConfig]
        var defaultModel: String?
        var defaultEffort: String?
        var defaultPermissionMode: String?
        var transcriptWidth: String?
    }

    private func load() {
        if let data = defaults.data(forKey: Self.hostsKey), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            hosts = s.hosts
            defaultModel = s.defaultModel
            defaultEffort = s.defaultEffort
            defaultPermissionMode = s.defaultPermissionMode ?? "default"
            transcriptWidth = s.transcriptWidth.flatMap(TranscriptWidth.init(rawValue:)) ?? .narrow
        }
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
    }

    private func save() {
        let s = Stored(hosts: hosts, defaultModel: defaultModel, defaultEffort: defaultEffort,
                       defaultPermissionMode: defaultPermissionMode, transcriptWidth: transcriptWidth.rawValue)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.hostsKey) }
    }
}

#if DEBUG
extension AppModel {
    /// Replaces `hosts`/`connections` with pre-seeded ones for `#Preview`s, bypassing persistence
    /// and the real `HostConnection(host:)` this init would otherwise create. Never touches the
    /// network.
    public static func sample(connections: [HostConnection] = [.sample()]) -> AppModel {
        // An ephemeral suite so previews never read or write the app's real saved hosts.
        let app = AppModel(defaults: UserDefaults(suiteName: "tether.preview.\(UUID().uuidString)") ?? .standard)
        app.hosts = connections.map(\.host)
        app.connections = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        app.newChat()
        return app
    }
}
#endif
