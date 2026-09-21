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
    /// Resolved here rather than in a view body: resolving can create the thread's model.
    public var selection: SidebarSelection? { didSet { resolveSelection(leaving: oldValue) } }
    public private(set) var selectedThread: ThreadModel?

    /// Whether the trailing inspector is shown (persisted).
    public var showInspector: Bool {
        get { access(keyPath: \.showInspector); return inspectorStorage }
        // Guarded like @Observable's own setters; the framework rewrites this value often.
        set {
            guard newValue != inspectorStorage else { return }
            withMutation(keyPath: \.showInspector) { inspectorStorage = newValue }
        }
    }
    @ObservationIgnored @AppStorage("tether.inspector") private var inspectorStorage = false

    /// The New Chat screen's session controls, reset to the defaults by `newChat()`.
    public var draftModel: String?
    public var draftEffort: EffortLevel?
    public var draftPermissionMode: PermissionMode = .default

    /// How wide the transcript may get (persisted).
    public var transcriptWidth: TranscriptWidth = .narrow { didSet { save() } }

    /// Defaults for new threads, per app (persisted).
    public var defaultModel: String? { didSet { save() } }
    public var defaultEffort: String? { didSet { save() } }
    public var defaultPermissionMode: String = "default" { didSet { save() } }

    private let defaults: UserDefaults
    private static let hostsKey = "tether.hosts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Same store as `defaults`, so previews never touch the real value.
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
        // Always a concrete model: the Settings default, else the catalog's.
        draftModel = defaultModel ?? connections[host]?.models.defaultValue
        draftEffort = defaultEffort.map(EffortLevel.init(rawValue:))
        draftPermissionMode = PermissionMode(rawValue: defaultPermissionMode)
    }

    /// Whether a chat, rather than New Chat, is on screen.
    public var isThreadSelected: Bool {
        if case .thread = selection { return true }
        return false
    }

    public var selectedConnection: HostConnection? {
        selection.flatMap { connections[$0.hostId] }
    }

    private func resolveSelection(leaving old: SidebarSelection?) {
        let previous = selectedThread
        if case .thread(let h, let id) = selection, let c = connections[h] {
            selectedThread = c.thread(id)
        } else {
            selectedThread = nil
        }
        if let previous, previous !== selectedThread, let host = old?.hostId {
            connections[host]?.leave(previous)
        }
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
    /// Pre-seeded hosts and connections for `#Preview`s, off persistence and the network.
    public static func sample(connections: [HostConnection] = [.sample()]) -> AppModel {
        let app = AppModel(defaults: UserDefaults(suiteName: "tether.preview.\(UUID().uuidString)") ?? .standard)
        app.hosts = connections.map(\.host)
        app.connections = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        app.newChat()
        return app
    }
}
#endif
