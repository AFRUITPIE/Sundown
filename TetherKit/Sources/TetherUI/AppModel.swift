import AppKit
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

/// Which chats the sidebar lists (persisted).
public enum SidebarFilter: String, CaseIterable, Sendable {
    case all, working, waiting, archived

    public var label: String {
        switch self {
        case .all: "All Chats"
        case .working: "Working"
        case .waiting: "Waiting on You"
        case .archived: "Archived"
        }
    }

    /// Everything but Archived leaves archived chats out.
    @MainActor func includes(_ thread: ThreadModel) -> Bool {
        switch self {
        case .all: !thread.isArchived
        case .working: !thread.isArchived && thread.isRunning
        case .waiting: !thread.isArchived && (!thread.pending.isEmpty || thread.status == .requiresAction)
        case .archived: thread.isArchived
        }
    }
}

/// The inspector's panes, in toolbar order (persisted).
public enum InspectorPane: String, CaseIterable, Identifiable, Sendable {
    case tasks, session, mcp, changes

    public var id: Self { self }

    public var label: String {
        switch self {
        case .tasks: "Tasks"
        case .session: "Session"
        case .mcp: "MCP"
        case .changes: "Changes"
        }
    }

    var symbol: String {
        switch self {
        case .tasks: "checklist"
        case .session: "info"
        case .mcp: "puzzlepiece.extension"
        case .changes: "plus.forwardslash.minus"
        }
    }

    /// ⌥⌘1, ⌥⌘2, ⌥⌘3, as Xcode numbers its inspectors.
    var shortcut: KeyEquivalent {
        switch self {
        case .tasks: "1"
        case .session: "2"
        case .mcp: "3"
        case .changes: "4"
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

    /// Which chats the sidebar lists (persisted).
    public var sidebarFilter: SidebarFilter = .all { didSet { save() } }

    /// Chats pinned to the top of the sidebar, by host (persisted). Kept here rather than on the
    /// host: pinning is how this Mac lists them, not something Claude Code knows about.
    public private(set) var pinnedChats: [UUID: Set<String>] = [:]

    public func isPinned(_ threadID: String, on host: UUID) -> Bool {
        pinnedChats[host]?.contains(threadID) == true
    }

    public func setPinned(_ pinned: Bool, _ threadID: String, on host: UUID) {
        guard pinned != isPinned(threadID, on: host) else { return }
        var ids = pinnedChats[host] ?? []
        if pinned { ids.insert(threadID) } else { ids.remove(threadID) }
        pinnedChats[host] = ids.isEmpty ? nil : ids
        save()
    }

    /// How wide the transcript may get (persisted).
    public var transcriptWidth: TranscriptWidth = .narrow { didSet { save() } }

    /// The transcript and composer's text size, 1 being the system's (persisted).
    public var textScale: CGFloat = 1 { didSet { save() } }

    /// Settings ▸ General and Advanced (persisted under a key of its own).
    public var appearance = Appearance() {
        didSet {
            if appearance.sessionTools != oldValue.sessionTools {
                for c in connections.values { c.offersSessionTools = appearance.sessionTools }
            }
            guard !isLoading, appearance != oldValue, let data = try? JSONEncoder().encode(appearance) else { return }
            defaults.set(data, forKey: Self.appearanceKey)
        }
    }

    /// Settings ▸ Notifications (persisted under a key of its own).
    public var alerts = AlertPreferences() {
        didSet {
            guard !isLoading, alerts != oldValue, let data = try? JSONEncoder().encode(alerts) else { return }
            defaults.set(data, forKey: Self.alertsKey)
        }
    }

    /// Notifications, the Dock badge and the Dock menu, once the app starts them.
    @ObservationIgnored private(set) var attention: AttentionCenter?
    /// Whether the first window of this launch has opened, which opens where the most recently
    /// used window left off when the system restores none.
    @ObservationIgnored private var launchWindowOpened = false

    /// What a window opens on when nothing says: the first window of a launch, where the most
    /// recently used window was; every other, New Chat on the host most recently used.
    public func newWindowTarget() -> WindowTarget {
        defer { launchWindowOpened = true }
        return WindowTarget(hostID: lastHostID, threadID: launchWindowOpened ? nil : lastThreadID)
    }

    /// A window started, a restored one included: any window opened after it is a new one.
    func windowStarted() { launchWindowOpened = true }

    /// The chat the launch's first window shows (`openOnLaunch`), handed out once.
    @ObservationIgnored private var launchChat: (host: UUID, thread: String)?

    func takeLaunchChat() -> (host: UUID, thread: String)? {
        defer { launchChat = nil }
        return launchChat
    }

    /// Starts notifications and the Dock badge. The app calls this; tests and previews don't, so
    /// nothing there reaches Notification Center.
    public func startAttention() {
        guard attention == nil else { return }
        let uiTest = ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1"
        attention = AttentionCenter(app: self, deliversToSystem: !uiTest)
    }

    /// The Dock icon's menu.
    public func dockMenu() -> NSMenu? { attention?.dockMenu() }

    /// Whether the app is frontmost, which the app delegate sets. A notification is for when it
    /// isn't, or the chat isn't the one in front. Not the scene phase: on the Mac that stays active
    /// while a window is visible, with another app in front.
    @ObservationIgnored public var isActive = true

    /// Opens a URL with the app's own action, for `open(_:)`.
    @ObservationIgnored public var openURL: ((URL) -> Void)?

    /// Shows what `link` names — a notification's chat, the Dock menu's New Chat — by opening it,
    /// so SwiftUI picks the window (`WindowRoot`'s `handlesExternalEvents`).
    public func open(_ link: TetherLink) {
        startAttention()
        if let openURL { openURL(link.url) } else { NSWorkspace.shared.open(link.url) }
    }

    /// Defaults for new threads, per app (persisted).
    public var defaultModel: String? { didSet { save() } }
    public var defaultEffort: String? { didSet { save() } }
    public var defaultPermissionMode: String = "default" { didSet { save() } }

    /// Each chat's unsent composer text, by thread id (persisted), so switching chats, closing a
    /// window or quitting doesn't lose it. Not observed: it changes on every keystroke, and a
    /// composer reads it only when it appears. Text put in a field from outside goes through
    /// `draftDeliveries` instead.
    @ObservationIgnored public private(set) var drafts: [String: String] = [:]

    /// A draft put in a composer from outside it (Shortcuts' Start a Chat), by draft key. Each
    /// composer showing that key applies a new one once, by its id; observed, and changed only by a
    /// delivery, so typing doesn't redraw every composer.
    public private(set) var draftDeliveries: [String: DraftDelivery] = [:]

    public struct DraftDelivery: Equatable, Sendable {
        public let id = UUID()
        public let text: String
    }

    /// The pending write of `drafts`: made once typing pauses, not per keystroke.
    @ObservationIgnored private var draftsSave: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    private let defaults: UserDefaults
    private let draftStore: DraftStore
    private static let hostsKey = "tether.hosts.v1"
    private static let draftsKey = "tether.drafts.v1"
    private static let appearanceKey = "tether.appearance.v1"
    private static let alertsKey = "tether.alerts.v1"
    /// `didSet` runs while `load()` restores values; saving then would write half-restored state.
    private var isLoading = false
    private var connectedAll = false
    /// How many windows show each thread: a followed thread is let go only when none does.
    @ObservationIgnored private var viewers: [ObjectIdentifier: Int] = [:]

    /// Hosts' environment values, by host id. The Keychain for the app's own defaults; anything
    /// with its own defaults (tests, previews, UI tests) keeps them in memory instead.
    private let secrets: SecretStore
    /// What each host's environment was when last written, so saving doesn't touch the Keychain
    /// for every change of selection.
    private var writtenEnv: [UUID: [String: String]] = [:]

    public convenience init(defaults: UserDefaults = .standard) {
        let standard = defaults === UserDefaults.standard
        self.init(defaults: defaults, secrets: standard ? KeychainSecrets() : DefaultsSecrets(defaults),
                  draftStore: standard ? FileDrafts.standard : DefaultsDrafts(defaults: defaults, key: Self.draftsKey))
    }

    init(defaults: UserDefaults, secrets: SecretStore, draftStore: DraftStore? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        self.draftStore = draftStore ?? DefaultsDrafts(defaults: defaults, key: Self.draftsKey)
        load()
        for h in hosts { connections[h.id] = HostConnection(host: h) }
        for c in connections.values { c.offersSessionTools = appearance.sessionTools }
        // A draft typed just before quitting is written then.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDrafts() }
        }
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
        c.offersSessionTools = appearance.sessionTools
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
        secrets.write(nil, for: id.uuidString)
        writtenEnv[id] = nil
        pinnedChats[id] = nil
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
        windowStarted()
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

    /// Kept at once, written once typing pauses: encoding every draft into the defaults file on each
    /// keystroke was most of what typing cost.
    public func setDraft(_ text: String, for threadID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : text
        guard drafts[threadID] != next else { return }
        drafts[threadID] = next
        draftsSave?.cancel()
        draftsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveDrafts()
        }
    }

    /// Puts `text` in the composer for `key`, whichever window shows it, and keeps it as its draft.
    public func deliverDraft(_ text: String, for key: String) {
        setDraft(text, for: key)
        draftDeliveries[key] = DraftDelivery(text: text)
    }

    /// Writes the drafts now rather than when typing pauses.
    public func saveDrafts() {
        draftsSave?.cancel()
        draftsSave = nil
        draftStore.write(drafts)
    }

    /// A deleted chat's draft goes with it.
    public func forgetDraft(for threadID: String) {
        guard drafts.removeValue(forKey: threadID) != nil else { return }
        saveDrafts()
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
        var sidebarFilter: String?
        /// By host id.
        var pinnedChats: [String: [String]]?
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let stored = defaults.data(forKey: Self.hostsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        hosts = stored?.hosts ?? []
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
        for i in hosts.indices {
            // A store from before the Keychain kept them has them inline; they move on the next save.
            guard hosts[i].env.isEmpty else { continue }
            if let data = secrets.read(hosts[i].id.uuidString),
               let env = try? JSONDecoder().decode([String: String].self, from: data) {
                hosts[i].env = env
                writtenEnv[hosts[i].id] = env
            }
        }
        drafts = draftStore.read()
        // Drafts kept in the defaults file before they had one of their own move to it, once.
        if !(draftStore is DefaultsDrafts), let old = defaults.data(forKey: Self.draftsKey) {
            let legacy = (try? JSONDecoder().decode([String: String].self, from: old)) ?? [:]
            drafts.merge(legacy) { current, _ in current }
            if draftStore.write(drafts) { defaults.removeObject(forKey: Self.draftsKey) }
        }
        appearance = defaults.data(forKey: Self.appearanceKey).flatMap { try? JSONDecoder().decode(Appearance.self, from: $0) } ?? Appearance()
        alerts = defaults.data(forKey: Self.alertsKey).flatMap { try? JSONDecoder().decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        guard let s = stored else { return }
        defaultModel = s.defaultModel
        defaultEffort = s.defaultEffort
        defaultPermissionMode = s.defaultPermissionMode ?? "default"
        transcriptWidth = s.transcriptWidth.flatMap(TranscriptWidth.init(rawValue:)) ?? .narrow
        lastShowInspector = s.showInspector ?? false
        lastInspectorPane = s.inspectorPane.flatMap(InspectorPane.init(rawValue:)) ?? .tasks
        sidebarGrouping = s.sidebarGrouping.flatMap(SidebarGrouping.init(rawValue:)) ?? .date
        textScale = s.textScale.map { CGFloat($0) } ?? 1
        sidebarFilter = s.sidebarFilter.flatMap(SidebarFilter.init(rawValue:)) ?? .all
        for (host, ids) in s.pinnedChats ?? [:] {
            if let id = UUID(uuidString: host), !ids.isEmpty { pinnedChats[id] = Set(ids) }
        }
        // A remembered host can disappear between launches; this Mac is always configured.
        if let id = s.hostID, hosts.contains(where: { $0.id == id }) {
            lastHostID = id
            lastThreadID = s.threadID
        }
    }

    private func save() {
        guard !isLoading else { return }
        for host in hosts where writtenEnv[host.id] ?? [:] != host.env {
            if secrets.write(host.env.isEmpty ? nil : try? JSONEncoder().encode(host.env), for: host.id.uuidString) {
                writtenEnv[host.id] = host.env
            }
        }
        // The defaults file keeps everything but the values, unless the Keychain refused them: then
        // they stay inline, as a store from before the Keychain has them, until a save gets them there.
        let hosts = hosts.map { host in
            var h = host
            if writtenEnv[host.id] ?? [:] == host.env { h.env = [:] }
            return h
        }
        let s = Stored(hosts: hosts, defaultModel: defaultModel, defaultEffort: defaultEffort,
                       defaultPermissionMode: defaultPermissionMode, transcriptWidth: transcriptWidth.rawValue,
                       showInspector: lastShowInspector, inspectorPane: lastInspectorPane.rawValue, hostID: lastHostID,
                       sidebarGrouping: sidebarGrouping.rawValue, threadID: lastThreadID, textScale: Double(textScale),
                       sidebarFilter: sidebarFilter.rawValue,
                       pinnedChats: Dictionary(uniqueKeysWithValues: pinnedChats.map { ($0.key.uuidString, $0.value.sorted()) }))
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.hostsKey) }
    }
}

extension AppModel {
    /// The launch's first window shows `threadID`, whether it's restored or new: the debug-only
    /// `TETHER_OPEN_THREAD` launch hook.
    public func openOnLaunch(threadID: String, on host: UUID) {
        lastHostID = host
        lastThreadID = threadID
        launchChat = (host, threadID)
    }
}

extension AppModel {
    /// The launched XCTest app uses the real UI and reducer with only in-process transports. In
    /// every build (the performance tests run against Release), used only with TETHER_UI_TEST_MODE.
    public static func uiTestFixture() -> AppModel {
        let failedConnects = ProcessInfo.processInfo.environment["TETHER_UI_TEST_SCENARIO"] == "connect-failure" ? 2 : 0
        let pendingPermission = ProcessInfo.processInfo.environment["TETHER_UI_TEST_SCENARIO"] == "permission"
        let performance = ProcessInfo.processInfo.environment["TETHER_UI_TEST_SCENARIO"] == "performance"
        let ssh = HostConfig(name: "Fixture SSH", kind: .ssh(destination: "fixture.invalid"))
        // A fresh store each launch, unless a test that relaunches names one to keep.
        let suite = ProcessInfo.processInfo.environment["TETHER_UI_TEST_DEFAULTS"]
        let app = sample(connections: [
            UITestFixture.connection(failedConnects: failedConnects, pendingPermission: pendingPermission, performance: performance),
            UITestFixture.connection(host: ssh)
        ], defaults: suite.flatMap(UserDefaults.init(suiteName:)))
        // The first window opens on the fixture's chat, or where the kept store says it was.
        if app.lastThreadID == nil { app.lastThreadID = UITestFixture.threadID }
        // Settings a test starts from, as the JSON Settings stores.
        if let json = ProcessInfo.processInfo.environment["TETHER_UI_TEST_APPEARANCE"],
           let appearance = try? JSONDecoder().decode(Appearance.self, from: Data(json.utf8)) {
            app.appearance = appearance
        }
        return app
    }

    /// Pre-seeded hosts and connections for `#Preview`s and tests, off persistence and the network.
    public static func sample(connections: [HostConnection], defaults: UserDefaults? = nil) -> AppModel {
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


#if DEBUG
extension AppModel {
    /// One sample connection, for `#Preview`s.
    public static func sample() -> AppModel { sample(connections: [.sample()]) }
}
#endif
