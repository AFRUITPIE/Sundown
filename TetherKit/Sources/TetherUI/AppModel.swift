import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import TetherKit
import TetherProtocol

/// How the sidebar groups a host's chats (persisted).
public enum SidebarGrouping: String, CaseIterable, Sendable {
    case date, directory

    public var label: String {
        switch self {
        case .date: "Date"
        case .directory: "Directory"
        }
    }
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

    /// What the sidebar says when nothing passes the filter, as a whole title.
    public var emptyTitle: String {
        switch self {
        case .all: "No Chats"
        case .working: "No Working Chats"
        case .waiting: "No Chats Waiting on You"
        case .archived: "No Archived Chats"
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
    /// isn't, or the chat isn't the one in front, and decorative motion stops while it isn't. Not
    /// the scene phase: on the Mac that stays active while a window is visible, with another app
    /// in front.
    public var isActive = true

    /// Opens a URL with the app's own action, for `open(_:)`.
    @ObservationIgnored public var openURL: ((URL) -> Void)?

    /// Shows what `link` names — a notification's chat, the Dock menu's New Chat — by opening it,
    /// so SwiftUI picks the window (`WindowRoot`'s `handlesExternalEvents`).
    public func open(_ link: TetherLink) {
        startAttention()
        if let openURL { openURL(link.url) } else { NSWorkspace.shared.open(link.url) }
    }

    /// Each chat's unsent composer text, by thread id (persisted), so switching chats, closing a
    /// window or quitting doesn't lose it. Not observed: it changes on every keystroke, and a
    /// composer reads it only when it appears. Text put in a field from outside goes through
    /// `draftDeliveries` instead. Read from the store the first time a composer asks (the file is
    /// read ahead off the main thread as the app starts).
    private var drafts: [String: String] {
        get {
            if let loadedDrafts { return loadedDrafts }
            let drafts = loadDrafts()
            loadedDrafts = drafts
            return drafts
        }
        set { loadedDrafts = newValue }
    }
    @ObservationIgnored private var loadedDrafts: [String: String]?
    /// Changed since last written: a quit with nothing typed writes nothing.
    @ObservationIgnored private var draftsChanged = false

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
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    private let defaults: UserDefaults
    private let draftQueue: DraftQueue
    private static let hostsKey = "tether.hosts.v1"
    private static let windowKey = "tether.window.v1"
    private static let draftsKey = "tether.drafts.v1"
    private static let appearanceKey = "tether.appearance.v1"
    private static let alertsKey = "tether.alerts.v1"
    /// `didSet` runs while `load()` restores values; saving then would write half-restored state.
    private var isLoading = false
    private var connectedAll = false
    /// Hosts no window showed when the app connected, connected once those that did are up.
    @ObservationIgnored private(set) var waitingHosts: Set<UUID> = []
    /// What each defaults key was last written with, or read as, so the same bytes aren't written again.
    @ObservationIgnored private var written: [String: Data] = [:]

    /// Whether decorative motion is left out to save energy (`ReducedEffects`), put in the
    /// environment beside the settings.
    public var reducesEffects: Bool { effects.savingEnergy || !isActive }
    private let effects = ReducedEffects()
    /// How many windows show each thread: a followed thread is let go only when none does.
    @ObservationIgnored private var viewers: [ObjectIdentifier: Int] = [:]

    /// Hosts' environment values, by host id. The Keychain for the app's own defaults; anything
    /// with its own defaults (tests, previews, UI tests) keeps them in memory instead.
    private let secrets: SecretStore
    /// What each host's environment was when last written, so saving doesn't touch the Keychain
    /// for every change of selection.
    private var writtenEnv: [UUID: [String: String]] = [:]
    /// Hosts whose values are in the Keychain and not read yet: each is read, off the main thread,
    /// just before its host connects (`loadEnvironment`), rather than every host's at launch.
    @ObservationIgnored private var unreadEnvironment: Set<UUID> = []
    /// Whether the store said which hosts have values. One from an older build didn't, so each host
    /// is read once and the next save says.
    @ObservationIgnored private var environmentRecorded = true

    public convenience init(defaults: UserDefaults = .standard) {
        let standard = defaults === UserDefaults.standard
        self.init(defaults: defaults, secrets: standard ? KeychainSecrets() : DefaultsSecrets(defaults),
                  draftStore: standard ? FileDrafts.standard : DefaultsDrafts(defaults: defaults, key: Self.draftsKey))
    }

    init(defaults: UserDefaults, secrets: SecretStore, draftStore: DraftStore? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        self.draftQueue = DraftQueue(store: draftStore ?? DefaultsDrafts(defaults: defaults, key: Self.draftsKey))
        load()
        for h in hosts { connections[h.id] = makeConnection(h) }
        // A draft typed just before quitting is written then.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDrafts() }
        }
        // A host that dropped while the Mac slept is tried again at once, not at the end of a wait
        // that may have grown long.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryConnections() }
        }
    }

    public func connection(_ id: UUID) -> HostConnection? { connections[id] }

    private func makeConnection(_ h: HostConfig) -> HostConnection {
        let c = HostConnection(host: h)
        c.offersSessionTools = appearance.sessionTools
        if unreadEnvironment.contains(h.id) {
            c.loadEnvironment = { [weak self] in await self?.loadEnvironment(for: h.id) }
        }
        return c
    }

    /// Connects every host once, however many windows open. The hosts windows show go first: the
    /// restored chat's history waited behind every other host's SSH login. The rest follow once
    /// those are up and have loaded their chats, or after a few seconds, or as soon as a window
    /// shows one.
    public func connectAll() {
        guard !connectedAll else { return }
        connectedAll = true
        var shown = Set(openWindows.map(\.hostID))
        shown.insert(lastHostID)
        if let launchChat { shown.insert(launchChat.host) }
        waitingHosts = Set(connections.keys).subtracting(shown)
        let first = shown.compactMap { connections[$0] }.map { c in Task { await c.connect() } }
        guard !waitingHosts.isEmpty else { return }
        Task { [weak self] in
            await Self.finished(first, orAfter: .seconds(5))
            self?.connectWaitingHosts()
        }
    }

    /// The hosts that were left to wait.
    private func connectWaitingHosts() {
        let waiting = waitingHosts
        waitingHosts = []
        for id in waiting { if let c = connections[id] { Task { await c.connect() } } }
    }

    /// A window shows `id`: it doesn't wait for the others.
    private func connectIfWaiting(_ id: UUID) {
        guard waitingHosts.remove(id) != nil, let c = connections[id] else { return }
        Task { await c.connect() }
    }

    /// Returns when every task has, or after `limit`, whichever is first.
    private static func finished(_ tasks: [Task<Void, Never>], orAfter limit: Duration) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task { for t in tasks { await t.value }; if once.claim() { done.resume() } }
            Task { try? await Task.sleep(for: limit); if once.claim() { done.resume() } }
        }
    }

    /// Hosts that dropped are tried again now, their backoff started over: the Mac woke.
    func retryConnections() {
        for c in connections.values { c.retryNow() }
    }

    public func addHost(_ h: HostConfig) {
        hosts.append(h)
        let c = makeConnection(h)
        connections[h.id] = c
        save()
        Task { await c.connect() }
    }

    public func updateHost(_ h: HostConfig) {
        guard let i = hosts.firstIndex(where: { $0.id == h.id }) else { return }
        var h = h
        if unreadEnvironment.remove(h.id) != nil {
            // Changed before its values were read, so Settings didn't show them: kept under what
            // was typed rather than lost.
            let stored = readEnvironment(secrets.read(h.id.uuidString))
            writtenEnv[h.id] = stored
            h.env = stored.merging(h.env) { _, typed in typed }
            connections[h.id]?.loadEnvironment = nil
        }
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
        unreadEnvironment.remove(id)
        waitingHosts.remove(id)
        pinnedChats[id] = nil
        if let c = connections.removeValue(forKey: id) { Task { await c.disconnect() } }
        if lastHostID == id { lastHostID = HostConfig.local.id; lastThreadID = nil }
        for window in openWindows { window.hostRemoved(id) }
        save()
        saveWindow()
    }

    /// `id`'s environment values: read from the Keychain, off the main thread, the first time
    /// they're asked for, which is just before the host connects.
    func loadEnvironment(for id: UUID) async -> [String: String] {
        guard unreadEnvironment.contains(id) else { return hosts.first { $0.id == id }?.env ?? [:] }
        let secrets = secrets
        let data = await Task.detached(priority: .userInitiated) { secrets.read(id.uuidString) }.value
        // Read meanwhile, by a change in Settings.
        guard unreadEnvironment.remove(id) != nil else { return hosts.first { $0.id == id }?.env ?? [:] }
        let env = readEnvironment(data)
        writtenEnv[id] = env
        if let i = hosts.firstIndex(where: { $0.id == id }) { hosts[i].env = env }
        // Record which hosts have values, for a store that didn't say or was wrong.
        if !environmentRecorded || env.isEmpty { save() }
        return env
    }

    private func readEnvironment(_ data: Data?) -> [String: String] {
        data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
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
        connectIfWaiting(window.hostID)
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
        saveWindow()
        connectIfWaiting(window.hostID)
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
        draftsChanged = true
        draftsSave?.cancel()
        draftsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.writeDrafts()
        }
    }

    /// Puts `text` in the composer for `key`, whichever window shows it, and keeps it as its draft.
    public func deliverDraft(_ text: String, for key: String) {
        setDraft(text, for: key)
        draftDeliveries[key] = DraftDelivery(text: text)
    }

    /// Writes the drafts in the background, if they changed: encoded and written off the main
    /// thread, after any write before it.
    private func writeDrafts() {
        draftsSave?.cancel()
        draftsSave = nil
        guard draftsChanged, let loadedDrafts else { return }
        draftsChanged = false
        draftQueue.write(loadedDrafts)
    }

    /// Writes the drafts now, rather than when typing pauses, and waits: at quit. Nothing if they
    /// haven't changed since they were last written.
    public func saveDrafts() {
        draftsSave?.cancel()
        draftsSave = nil
        guard let loadedDrafts, draftsChanged || draftQueue.lastWriteFailed else { return }
        draftsChanged = !draftQueue.writeAndWait(loadedDrafts)
    }

    /// Returns once the drafts' background writes so far are done.
    func waitForDraftWrites() { draftQueue.waitForWrites() }

    /// A deleted chat's draft goes with it.
    public func forgetDraft(for threadID: String) {
        guard drafts.removeValue(forKey: threadID) != nil else { return }
        draftsChanged = true
        writeDrafts()
    }

    /// The store's drafts, and any the defaults file kept before drafts had a file of their own,
    /// which move to it, once.
    private func loadDrafts() -> [String: String] {
        var drafts = draftQueue.read()
        guard !(draftQueue.store is DefaultsDrafts), let old = defaults.data(forKey: Self.draftsKey) else { return drafts }
        let legacy = (try? JSONDecoder().decode([String: String].self, from: old)) ?? [:]
        drafts.merge(legacy) { current, _ in current }
        if draftQueue.writeAndWait(drafts) { defaults.removeObject(forKey: Self.draftsKey) }
        return drafts
    }

    // MARK: persistence

    // Everything but `hosts` is optional, so a store written by an older build still decodes.
    private struct Stored: Codable {
        var hosts: [HostConfig]
        /// Once the app's own permission mode for new chats; the host's Claude Code decides now.
        var defaultPermissionMode: String?
        var transcriptWidth: String?
        /// Where the last window was: in `LastWindow` now, read from here once.
        var showInspector: Bool?
        var inspectorPane: String?
        var hostID: UUID?
        var sidebarGrouping: String?
        var threadID: String?
        var textScale: Double?
        var sidebarFilter: String?
        /// By host id.
        var pinnedChats: [String: [String]]?
        /// The hosts whose environment values are in the Keychain. Nil in a store from before it
        /// was kept, which has every host's read once.
        var environmentHosts: [String]?
    }

    /// Where the most recently used window was, under a key of its own: it changes with every chat
    /// switch and inspector change, and with the rest it wrote the hosts, pins and preferences again
    /// each time.
    private struct LastWindow: Codable {
        var hostID: UUID?
        var threadID: String?
        var showInspector: Bool?
        var inspectorPane: String?
    }

    /// Sorted keys, so the same values are the same bytes and an unchanged save writes nothing.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let storedData = defaults.data(forKey: Self.hostsKey)
        written[Self.hostsKey] = storedData
        let stored = storedData.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        hosts = stored?.hosts ?? []
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
        // Values are read from the Keychain just before their host connects, and only for a host
        // that has some. A store from before the Keychain kept them has them inline; they move on
        // the next save.
        let withValues = stored?.environmentHosts.map { Set($0.compactMap(UUID.init(uuidString:))) }
        environmentRecorded = withValues != nil
        for host in hosts where host.env.isEmpty && withValues?.contains(host.id) != false {
            unreadEnvironment.insert(host.id)
        }
        appearance = defaults.data(forKey: Self.appearanceKey).flatMap { try? JSONDecoder().decode(Appearance.self, from: $0) } ?? Appearance()
        alerts = defaults.data(forKey: Self.alertsKey).flatMap { try? JSONDecoder().decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        if let s = stored {
            transcriptWidth = s.transcriptWidth.flatMap(TranscriptWidth.init(rawValue:)) ?? .narrow
            sidebarGrouping = s.sidebarGrouping.flatMap(SidebarGrouping.init(rawValue:)) ?? .date
            textScale = s.textScale.map { CGFloat($0) } ?? 1
            sidebarFilter = s.sidebarFilter.flatMap(SidebarFilter.init(rawValue:)) ?? .all
            for (host, ids) in s.pinnedChats ?? [:] {
                if let id = UUID(uuidString: host), !ids.isEmpty { pinnedChats[id] = Set(ids) }
            }
        }
        let windowData = defaults.data(forKey: Self.windowKey)
        written[Self.windowKey] = windowData
        let window = windowData.flatMap { try? JSONDecoder().decode(LastWindow.self, from: $0) }
            // Kept with the rest by an older build: taken from there, once.
            ?? stored.map { LastWindow(hostID: $0.hostID, threadID: $0.threadID, showInspector: $0.showInspector, inspectorPane: $0.inspectorPane) }
        lastShowInspector = window?.showInspector ?? false
        lastInspectorPane = window?.inspectorPane.flatMap(InspectorPane.init(rawValue:)) ?? .tasks
        // A remembered host can disappear between launches; this Mac is always configured.
        if let id = window?.hostID, hosts.contains(where: { $0.id == id }) {
            lastHostID = id
            lastThreadID = window?.threadID
        }
        // Moved to its own key now, not when a window next changes: an older build's fields go
        // with the next save of the rest.
        if windowData == nil, stored?.hostID != nil {
            isLoading = false
            saveWindow()
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
        let inKeychain = self.hosts.filter { unreadEnvironment.contains($0.id) || !(writtenEnv[$0.id] ?? [:]).isEmpty }
        let s = Stored(hosts: hosts, transcriptWidth: transcriptWidth.rawValue,
                       sidebarGrouping: sidebarGrouping.rawValue, textScale: Double(textScale),
                       sidebarFilter: sidebarFilter.rawValue,
                       pinnedChats: Dictionary(uniqueKeysWithValues: pinnedChats.map { ($0.key.uuidString, $0.value.sorted()) }),
                       environmentHosts: inKeychain.map(\.id.uuidString))
        write(try? Self.encoder.encode(s), forKey: Self.hostsKey)
        environmentRecorded = true
    }

    private func saveWindow() {
        guard !isLoading else { return }
        let window = LastWindow(hostID: lastHostID, threadID: lastThreadID,
                                showInspector: lastShowInspector, inspectorPane: lastInspectorPane.rawValue)
        write(try? Self.encoder.encode(window), forKey: Self.windowKey)
    }

    /// Writes `data` under `key` unless it's what the key already holds.
    private func write(_ data: Data?, forKey key: String) {
        guard let data, data != written[key] else { return }
        written[key] = data
        defaults.set(data, forKey: key)
    }
}

/// Resumes a continuation once, whichever of its callers comes first.
private final class ResumeOnce: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { if $0 { return false }; $0 = true; return true } }
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
        // A kept store has these hosts, as adding them in Settings would, so the last window's
        // host is still there on relaunch.
        if defaults != nil { app.save() }
        return app
    }
}


#if DEBUG
extension AppModel {
    /// One sample connection, for `#Preview`s.
    public static func sample() -> AppModel { sample(connections: [.sample()]) }
}
#endif
