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

/// App-wide state: configured hosts, their live connections, preferences, and each chat's unsent
/// draft. What a window shows is its own `WindowModel`; the most recently used window's state is
/// remembered here, so a new window or the next launch starts from it.
@MainActor
@Observable
public final class AppModel {
    public private(set) var hosts: [HostConfig] = []
    public private(set) var connections: [UUID: HostConnection] = [:]

    /// The most recently used window's host, chat and inspector (persisted).
    public private(set) var lastHostID: UUID = HostConfig.local.id
    public private(set) var lastThreadID: String?
    public private(set) var lastShowInspector = false
    public private(set) var lastInspectorPane: InspectorPane = .tasks

    /// How the sidebar groups chats (persisted).
    public var sidebarGrouping: SidebarGrouping = .date { didSet { save() } }

    /// How wide the transcript may get (persisted).
    public var transcriptWidth: TranscriptWidth = .narrow { didSet { save() } }

    /// The transcript and composer's text size, 1 being the system's (persisted).
    public var textScale: CGFloat = 1 { didSet { save() } }

    /// Settings ▸ Appearance (persisted under a key of its own).
    public var appearance = Appearance() {
        didSet {
            guard !isLoading, appearance != oldValue, let data = try? JSONEncoder().encode(appearance) else { return }
            defaults.set(data, forKey: Self.appearanceKey)
        }
    }

    /// Defaults for new threads, per app (persisted).
    public var defaultModel: String? { didSet { save() } }
    public var defaultEffort: String? { didSet { save() } }
    public var defaultPermissionMode: String = "default" { didSet { save() } }

    /// Each chat's unsent composer text, by thread id (persisted), so switching chats, closing a
    /// window or quitting doesn't lose it.
    public private(set) var drafts: [String: String] = [:]

    private let defaults: UserDefaults
    private static let hostsKey = "tether.hosts.v1"
    private static let draftsKey = "tether.drafts.v1"
    private static let appearanceKey = "tether.appearance.v1"
    /// `didSet` runs while `load()` restores values; saving then would write half-restored state.
    private var isLoading = false
    private var connectedAll = false
    /// How many windows show each thread: a followed thread is let go only when none does.
    @ObservationIgnored private var viewers: [ObjectIdentifier: Int] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        for h in hosts { connections[h.id] = HostConnection(host: h) }
    }

    public func connection(_ id: UUID) -> HostConnection? { connections[id] }

    /// Connects every host once, however many windows open.
    public func connectAll() {
        guard !connectedAll else { return }
        connectedAll = true
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

    /// Windows showing the host fall back to this Mac.
    public func removeHost(_ id: UUID) {
        guard id != HostConfig.local.id else { return }
        hosts.removeAll { $0.id == id }
        if let c = connections.removeValue(forKey: id) { Task { await c.disconnect() } }
        if lastHostID == id { lastHostID = HostConfig.local.id; lastThreadID = nil }
        for window in openWindows { window.hostRemoved(id) }
        save()
    }

    // MARK: windows

    private struct WeakWindow { weak var window: WindowModel? }
    @ObservationIgnored private var windowRefs: [WeakWindow] = []

    /// The windows on screen.
    public var openWindows: [WindowModel] { windowRefs.compactMap(\.window) }

    func register(_ window: WindowModel) {
        windowRefs.removeAll { $0.window == nil || $0.window === window }
        windowRefs.append(WeakWindow(window: window))
    }

    func unregister(_ window: WindowModel) {
        windowRefs.removeAll { $0.window == nil || $0.window === window }
    }

    /// A window changed what it shows: the next window, and the next launch, start from it.
    func remember(_ window: WindowModel) {
        lastHostID = window.hostID
        lastThreadID = window.threadID
        lastShowInspector = window.showInspector
        lastInspectorPane = window.inspectorPane
        save()
    }

    /// A window started showing `thread`.
    func retain(_ thread: ThreadModel?) {
        guard let thread else { return }
        viewers[ObjectIdentifier(thread), default: 0] += 1
    }

    /// Whether any window shows `thread`.
    func isShown(_ thread: ThreadModel?) -> Bool {
        thread.map { (viewers[ObjectIdentifier($0)] ?? 0) > 0 } ?? false
    }

    /// A window stopped showing `thread`; once no window does, its connection lets it go.
    func release(_ thread: ThreadModel?, on host: UUID?) {
        guard let thread, let host else { return }
        let key = ObjectIdentifier(thread)
        let count = (viewers[key] ?? 1) - 1
        if count > 0 { viewers[key] = count; return }
        viewers[key] = nil
        connections[host]?.leave(thread)
    }

    // MARK: drafts

    public func draft(for threadID: String) -> String { drafts[threadID] ?? "" }

    public func setDraft(_ text: String, for threadID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { drafts[threadID] = nil } else { drafts[threadID] = text }
        if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: Self.draftsKey) }
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
        var threadID: String?
        var textScale: Double?
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let stored = defaults.data(forKey: Self.hostsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        hosts = stored?.hosts ?? []
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
        drafts = defaults.data(forKey: Self.draftsKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        appearance = defaults.data(forKey: Self.appearanceKey).flatMap { try? JSONDecoder().decode(Appearance.self, from: $0) } ?? Appearance()
        guard let s = stored else { return }
        defaultModel = s.defaultModel
        defaultEffort = s.defaultEffort
        defaultPermissionMode = s.defaultPermissionMode ?? "default"
        transcriptWidth = s.transcriptWidth.flatMap(TranscriptWidth.init(rawValue:)) ?? .narrow
        lastShowInspector = s.showInspector ?? false
        lastInspectorPane = s.inspectorPane.flatMap(InspectorPane.init(rawValue:)) ?? .tasks
        sidebarGrouping = s.sidebarGrouping.flatMap(SidebarGrouping.init(rawValue:)) ?? .date
        textScale = s.textScale.map { CGFloat($0) } ?? 1
        // A remembered host can disappear between launches; this Mac is always configured.
        if let id = s.hostID, hosts.contains(where: { $0.id == id }) {
            lastHostID = id
            lastThreadID = s.threadID
        }
    }

    private func save() {
        guard !isLoading else { return }
        let s = Stored(hosts: hosts, defaultModel: defaultModel, defaultEffort: defaultEffort,
                       defaultPermissionMode: defaultPermissionMode, transcriptWidth: transcriptWidth.rawValue,
                       showInspector: lastShowInspector, inspectorPane: lastInspectorPane.rawValue, hostID: lastHostID,
                       sidebarGrouping: sidebarGrouping.rawValue, threadID: lastThreadID, textScale: Double(textScale))
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
        // A fresh store each launch, unless a test that relaunches names one to keep.
        let suite = ProcessInfo.processInfo.environment["TETHER_UI_TEST_DEFAULTS"]
        let app = sample(connections: [
            UITestFixture.connection(failFirstConnect: failFirst, pendingPermission: pendingPermission, performance: performance),
            UITestFixture.connection(host: ssh)
        ], defaults: suite.flatMap(UserDefaults.init(suiteName:)))
        // The first window opens on the fixture's chat, or where the kept store says it was.
        if app.lastThreadID == nil { app.lastThreadID = UITestFixture.threadID }
        return app
    }

    /// The first window opens on `threadID` (the `TETHER_OPEN_THREAD` launch hook).
    public func openOnLaunch(threadID: String, on host: UUID) {
        lastHostID = host
        lastThreadID = threadID
    }

    /// Pre-seeded hosts and connections for `#Preview`s and tests, off persistence and the network.
    public static func sample(connections: [HostConnection] = [.sample()], defaults: UserDefaults? = nil) -> AppModel {
        let app = AppModel(defaults: defaults ?? UserDefaults(suiteName: "tether.preview.\(UUID().uuidString)") ?? .standard)
        app.hosts = connections.map(\.host)
        app.connections = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        // A kept store (a relaunching UI test) says where the last window was; otherwise the
        // first connection, on New Chat.
        if defaults == nil || !connections.contains(where: { $0.id == app.lastHostID }) {
            app.lastHostID = connections.first?.id ?? HostConfig.local.id
            app.lastThreadID = nil
        }
        return app
    }
}
#endif
