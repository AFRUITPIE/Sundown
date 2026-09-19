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
    public var selection: SidebarSelection?
    /// Defaults for new threads, per app (persisted).
    public var defaultModel: String? { didSet { save() } }
    public var defaultEffort: String? { didSet { save() } }
    public var defaultPermissionMode: String = "default" { didSet { save() } }

    private let defaults: UserDefaults
    private static let hostsKey = "tether.hosts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        for h in hosts { connections[h.id] = HostConnection(host: h) }
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
        if selection?.hostId == id { selection = nil }
        save()
    }

    // MARK: selection helpers

    /// Start composing a new chat on the currently selected host (or this Mac).
    public func newChat() {
        selection = .newChat(host: selection?.hostId ?? HostConfig.local.id)
    }

    public var selectedConnection: HostConnection? {
        selection.flatMap { connections[$0.hostId] }
    }

    public var selectedThread: ThreadModel? {
        guard case .thread(let h, let id) = selection, let c = connections[h] else { return nil }
        return c.thread(id)
    }

    // MARK: persistence

    private struct Stored: Codable {
        var hosts: [HostConfig]
        var defaultModel: String?
        var defaultEffort: String?
        var defaultPermissionMode: String?
    }

    private func load() {
        if let data = defaults.data(forKey: Self.hostsKey), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            hosts = s.hosts
            defaultModel = s.defaultModel
            defaultEffort = s.defaultEffort
            defaultPermissionMode = s.defaultPermissionMode ?? "default"
        }
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
    }

    private func save() {
        let s = Stored(hosts: hosts, defaultModel: defaultModel, defaultEffort: defaultEffort, defaultPermissionMode: defaultPermissionMode)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.hostsKey) }
    }
}
