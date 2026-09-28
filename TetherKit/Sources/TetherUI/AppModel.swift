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

    /// The inspector column's width (Settings ▸ Advanced ▸ Show Panes In ▸ Inspector), set when a
    /// drag of its edge ends (persisted).
    public var inspectorWidth: CGFloat = InspectorWidth.ideal { didSet { save() } }

    /// Whether the floating inspector panel is open (Settings ▸ Advanced ▸ Inspector ▸ Floating
    /// Panel). The app's, not a window's: one panel serves whichever window is in front.
    public var inspectorPanelShown = false

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
    /// Opens a window on a target, for when none is left to show a chat in.
    @ObservationIgnored var openWindow: ((WindowTarget) -> Void)?

    /// Starts notifications and the Dock badge. The app calls this; tests and previews don't, so
    /// nothing there reaches Notification Center.
    public func startAttention() {
        guard attention == nil else { return }
        let uiTest = ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1"
        attention = AttentionCenter(app: self, deliversToSystem: !uiTest)
    }

    /// The Dock icon's menu.
    public func dockMenu() -> NSMenu? { attention?.dockMenu() }

    /// Brings a chat to the front, in the key window or a new one.
    public func showChat(host: UUID, threadID: String) {
        startAttention()
        attention?.open(host: host, threadID: threadID)
    }

    /// The app's model, for what reaches it from outside a window: Shortcuts.
    public private(set) static weak var current: AppModel?

    /// Shortcuts' Start a Chat: New Chat on this Mac, in `folder` if given, with `prompt` in the
    /// field — or sent, when `send` is set and there's a folder to start in.
    public func startChat(folder: String?, prompt: String?, send: Bool) async {
        showNewChat()
        // A window that had to open appears on the next turn of the run loop.
        for _ in 0..<20 where openWindows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = openWindows.first(where: \.isKey) ?? openWindows.first else { return }
        if window.hostID != HostConfig.local.id { window.hostID = HostConfig.local.id }
        window.newChat()
        if let folder, !folder.isEmpty { window.draftDirectory = (folder as NSString).expandingTildeInPath }
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        if send, window.draftDirectory != nil {
            await window.startDraftChat([.text(.init(text: text))])
        } else {
            deliverDraft(text, for: "new-chat:\(window.hostID)")
        }
    }

    /// New Chat in the front window, or a new window if none is open.
    public func showNewChat() {
        NSApp.activate()
        if let window = openWindows.first(where: \.isKey) ?? openWindows.first {
            window.newChat()
        } else {
            openWindow?(WindowTarget(hostID: lastHostID))
        }
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
        self.init(defaults: defaults, secrets: defaults === UserDefaults.standard ? KeychainSecrets() : DefaultsSecrets(defaults))
    }

    init(defaults: UserDefaults, secrets: SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        load()
        for h in hosts { connections[h.id] = HostConnection(host: h) }
        for c in connections.values { c.offersSessionTools = appearance.sessionTools }
        // Here, not when the first window appears: a Shortcut can launch the app and ask for a
        // chat before any window has.
        Self.current = self
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
    }

    func unregister(_ window: WindowModel) {
        windowRefs.removeAll { $0.window == nil || $0.window === window }
        if activeWindow === window { activeWindow = windowRefs.last?.window }
    }

    /// The chat window most recently in front: what the floating inspector panel shows. A panel
    /// doesn't get the main window's focused values, so the windows report themselves here.
    public private(set) var activeWindow: WindowModel?

    func activate(_ window: WindowModel) {
        if activeWindow !== window { activeWindow = window }
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
        var inspectorWidth: Double?
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
        drafts = defaults.data(forKey: Self.draftsKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
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
        inspectorWidth = s.inspectorWidth.map { InspectorWidth.clamp(CGFloat($0)) } ?? InspectorWidth.ideal
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
                       inspectorWidth: Double(inspectorWidth), sidebarFilter: sidebarFilter.rawValue,
                       pinnedChats: Dictionary(uniqueKeysWithValues: pinnedChats.map { ($0.key.uuidString, $0.value.sorted()) }))
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.hostsKey) }
    }
}

#if DEBUG
extension AppModel {
    /// The launched XCTest app uses the real UI and reducer with only in-process transports.
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
