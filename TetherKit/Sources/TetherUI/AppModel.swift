import Foundation
import Observation
import SwiftUI
import TetherKit
import TetherProtocol

/// How the sidebar groups a host's chats (persisted).
public enum SidebarGrouping: String, CaseIterable, Sendable {
    case date, directory

    public var label: String { rawValue.capitalized }
}

/// The inspector's panes, in toolbar order (persisted).
public enum InspectorPane: String, CaseIterable, Identifiable, Sendable {
    case tasks, session, mcp

    public var id: Self { self }

    public var label: String {
        switch self {
        case .tasks: "Tasks"
        case .session: "Session"
        case .mcp: "MCP"
        }
    }

    var symbol: String {
        switch self {
        case .tasks: "checklist"
        case .session: "info"
        case .mcp: "puzzlepiece.extension"
        }
    }

    /// ⌥⌘1, ⌥⌘2, ⌥⌘3, as Xcode numbers its inspectors.
    var shortcut: KeyEquivalent {
        switch self {
        case .tasks: "1"
        case .session: "2"
        case .mcp: "3"
        }
    }
}

/// App-wide state: configured hosts, their live connections, and what the window is showing.
@MainActor
@Observable
public final class AppModel {
    public private(set) var hosts: [HostConfig] = []
    public private(set) var connections: [UUID: HostConnection] = [:]

    /// The host the sidebar is showing (persisted). Changing it starts a new chat there.
    public var hostID: UUID = HostConfig.local.id {
        didSet {
            guard hostID != oldValue else { return }
            // A stored host can disappear between launches; this Mac is always configured.
            if connections[hostID] == nil && !hosts.contains(where: { $0.id == hostID }) {
                hostID = HostConfig.local.id
            }
            threadID = nil
            seedDraft()
            save()
        }
    }

    /// The chat on screen, or nil for New Chat.
    /// Resolved here rather than in a view body: resolving can create the thread's model.
    public var threadID: String? { didSet { resolveSelection() } }
    public private(set) var selectedThread: ThreadModel?
    /// Which host `selectedThread` came from, so it is left on the right connection.
    private var selectedThreadHost: UUID?

    /// Whether the trailing inspector is shown (persisted).
    public var showInspector = false { didSet { save() } }

    /// The pane the inspector shows, kept while it is closed (persisted).
    public var inspectorPane: InspectorPane = .tasks { didSet { save() } }

    /// True when the inspector is open on `pane`.
    public func isInspecting(_ pane: InspectorPane) -> Bool { showInspector && inspectorPane == pane }

    /// Shows `pane`, opening the inspector if it is closed.
    public func openInspector(on pane: InspectorPane) {
        if inspectorPane != pane { inspectorPane = pane }
        if !showInspector { showInspector = true }
    }


    /// How the sidebar groups chats (persisted).
    public var sidebarGrouping: SidebarGrouping = .date { didSet { save() } }

    /// The New Chat screen's session controls, reset to the defaults by `newChat()`.
    public var draftModel: String?
    public var draftEffort: EffortLevel?
    public var draftPermissionMode: PermissionMode = .default
    /// Carried into `startThread`; off unless the user asks for it on this chat.
    public var draftFastMode = false
    /// The New Chat folder: the host's most recent project until one is chosen, nil before the
    /// projects arrive.
    public var draftDirectory: String?
    /// Why the New Chat draft couldn't start, cleared with the draft.
    var draftError: String?

    /// How wide the transcript may get (persisted).
    public var transcriptWidth: TranscriptWidth = .narrow { didSet { save() } }

    /// Defaults for new threads, per app (persisted).
    public var defaultModel: String? { didSet { save() } }
    public var defaultEffort: String? { didSet { save() } }
    public var defaultPermissionMode: String = "default" { didSet { save() } }

    private let defaults: UserDefaults
    private static let hostsKey = "tether.hosts.v1"
    /// `didSet` runs while `load()` restores values; saving then would write half-restored state.
    private var isLoading = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        for h in hosts { connections[h.id] = HostConnection(host: h) }
        seedDraft()
    }

    public func connection(_ id: UUID) -> HostConnection? { connections[id] }

    /// The host the sidebar is showing.
    public var host: HostConfig? { hosts.first { $0.id == hostID } }

    /// The window's subtitle: the chat's folder name, or the New Chat folder's; the full path is in
    /// the Session pane, or the folder pop-up on New Chat. Prefixed with the host when there is
    /// more than one, since nothing else in the window names it.
    public var subtitle: String {
        let folder = selectedThread.map { $0.cwd } ?? draftDirectory
        let name = folder.map { ($0 as NSString).lastPathComponent } ?? ""
        guard hosts.count > 1, let host = host?.name else { return name }
        return name.isEmpty ? host : "\(host) · \(name)"
    }

    /// The connection for the host the sidebar is showing.
    public var connection: HostConnection? { connections[hostID] }

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
        // Falls back to this Mac; the `didSet` clears the chat and reseeds the draft.
        if hostID == id { hostID = HostConfig.local.id }
        save()
    }

    // MARK: selection helpers

    /// Start composing a new chat on the host the sidebar is showing.
    public func newChat() {
        threadID = nil
        seedDraft()
    }

    /// Show a chat, optionally switching host first (the debug launch hook does).
    public func open(threadID id: String, on host: UUID? = nil) {
        if let host, host != hostID { hostID = host }
        threadID = id
    }

    private func seedDraft() {
        // Always a concrete model: the Settings default, else the catalog's.
        draftModel = defaultModel ?? connections[hostID]?.models.defaultValue
        draftEffort = defaultEffort.map(EffortLevel.init(rawValue:))
        draftPermissionMode = PermissionMode(rawValue: defaultPermissionMode)
        draftFastMode = false
        draftDirectory = connections[hostID]?.projects.first?.cwd
        draftError = nil
    }

    private func resolveSelection() {
        let previous = selectedThread
        let previousHost = selectedThreadHost
        if let id = threadID, let c = connections[hostID] {
            selectedThread = c.thread(id)
            selectedThreadHost = hostID
        } else {
            selectedThread = nil
            selectedThreadHost = nil
        }
        if let previous, previous !== selectedThread, let previousHost {
            connections[previousHost]?.leave(previous)
        }
    }

    // MARK: persistence

    // Everything but `hosts` is optional, so a store written by an older build still decodes.
    private struct Stored: Codable {
        var hosts: [HostConfig]
        var defaultModel: String?
        var defaultEffort: String?
        var defaultPermissionMode: String?
        var transcriptWidth: String?
        var showInspector: Bool?
        var inspectorPane: String?
        var hostID: UUID?
        var sidebarGrouping: String?
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let stored = defaults.data(forKey: Self.hostsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        hosts = stored?.hosts ?? []
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
        guard let s = stored else { return }
        defaultModel = s.defaultModel
        defaultEffort = s.defaultEffort
        defaultPermissionMode = s.defaultPermissionMode ?? "default"
        transcriptWidth = s.transcriptWidth.flatMap(TranscriptWidth.init(rawValue:)) ?? .narrow
        showInspector = s.showInspector ?? false
        inspectorPane = s.inspectorPane.flatMap(InspectorPane.init(rawValue:)) ?? .tasks
        sidebarGrouping = s.sidebarGrouping.flatMap(SidebarGrouping.init(rawValue:)) ?? .date
        // After `hosts`: the setter validates against it.
        hostID = s.hostID ?? HostConfig.local.id
    }

    private func save() {
        guard !isLoading else { return }
        let s = Stored(hosts: hosts, defaultModel: defaultModel, defaultEffort: defaultEffort,
                       defaultPermissionMode: defaultPermissionMode, transcriptWidth: transcriptWidth.rawValue,
                       showInspector: showInspector, inspectorPane: inspectorPane.rawValue, hostID: hostID, sidebarGrouping: sidebarGrouping.rawValue)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.hostsKey) }
    }
}

#if DEBUG
extension AppModel {
    /// The launched XCTest app uses the real UI and reducer with only in-process transports.
    public static func uiTestFixture() -> AppModel {
        let failFirst = ProcessInfo.processInfo.environment["TETHER_UI_TEST_SCENARIO"] == "connect-failure"
        let pendingPermission = ProcessInfo.processInfo.environment["TETHER_UI_TEST_SCENARIO"] == "permission"
        let performance = ProcessInfo.processInfo.environment["TETHER_UI_TEST_SCENARIO"] == "performance"
        let ssh = HostConfig(name: "Fixture SSH", kind: .ssh(destination: "fixture.invalid"))
        let app = sample(connections: [
            UITestFixture.connection(failFirstConnect: failFirst, pendingPermission: pendingPermission, performance: performance),
            UITestFixture.connection(host: ssh)
        ])
        app.open(threadID: UITestFixture.threadID)
        return app
    }

    /// Pre-seeded hosts and connections for `#Preview`s and tests, off persistence and the network.
    public static func sample(connections: [HostConnection] = [.sample()], defaults: UserDefaults? = nil) -> AppModel {
        let app = AppModel(defaults: defaults ?? UserDefaults(suiteName: "tether.preview.\(UUID().uuidString)") ?? .standard)
        app.hosts = connections.map(\.host)
        app.connections = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        app.hostID = connections.first?.id ?? HostConfig.local.id
        app.newChat()
        return app
    }
}
#endif
