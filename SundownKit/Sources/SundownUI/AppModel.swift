import AppKit
import Foundation
import Observation
import SundownFixtures
import SwiftUI
import Synchronization
import SundownKit
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
        case .waiting: !thread.isArchived && thread.isWaitingOnYou
        case .archived: thread.isArchived
        }
    }
}

/// What a window's content shows: the chat, its tasks, or its working-tree diff. Each window's
/// own, kept as it moves between chats.
public enum WindowTab: String, CaseIterable, Identifiable, Sendable {
    case chat, tasks, diff

    public var id: Self { self }

    public var label: String {
        switch self {
        case .chat: "Chat"
        case .tasks: "Tasks"
        case .diff: "Diff"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .tasks: "checklist"
        case .diff: "plus.forwardslash.minus"
        }
    }

    /// ⌘1, ⌘2, ⌘3.
    var shortcut: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .tasks: "2"
        case .diff: "3"
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

    /// The most recently used window's host and chat (persisted).
    public private(set) var lastHostID: UUID = HostConfig.local.id
    public private(set) var lastThreadID: String?

    /// How the sidebar groups chats (persisted).
    public var sidebarGrouping: SidebarGrouping = .date { didSet { if sidebarGrouping != oldValue { save() } } }

    /// Which chats the sidebar lists (persisted).
    public var sidebarFilter: SidebarFilter = .all { didSet { if sidebarFilter != oldValue { save() } } }

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
    public var transcriptWidth: TranscriptWidth = .narrow { didSet { if transcriptWidth != oldValue { save() } } }

    /// The transcript and composer's text size, 1 being the system's (persisted).
    public var textScale: CGFloat = 1 { didSet { if textScale != oldValue { save() } } }

    /// Settings ▸ General and the View menu (persisted under a key of its own).
    public var appearance = Appearance() {
        didSet {
            if appearance.sessionTools != oldValue.sessionTools {
                for c in connections.values { c.offersSessionTools = appearance.sessionTools }
            }
            guard !isLoading, appearance != oldValue else { return }
            defaults.set(try? Self.encoder.encode(appearance), forKey: Self.appearanceKey)
        }
    }

    /// Settings ▸ Notifications (persisted under a key of its own).
    public var alerts = AlertPreferences() {
        didSet {
            guard !isLoading, alerts != oldValue else { return }
            defaults.set(try? Self.encoder.encode(alerts), forKey: Self.alertsKey)
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
        let uiTest = ProcessInfo.processInfo.environment["SUNDOWN_UI_TEST_MODE"] == "1"
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
    public func open(_ link: SundownLink) {
        if let openURL { openURL(link.url) } else { NSWorkspace.shared.open(link.url) }
    }

    /// Each chat's unsent composer text, by thread id (persisted in `Drafts.json`, read at launch),
    /// so switching chats, closing a window or quitting doesn't lose it. Not observed: it changes on
    /// every keystroke, and a composer reads it only when it appears. Text put in a field from
    /// outside goes through `draftDeliveries` instead.
    @ObservationIgnored private var drafts: [String: String]
    /// What the file holds, as last written or read: a save with nothing new writes nothing.
    @ObservationIgnored private var writtenDrafts: [String: String]

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
    /// Where drafts are kept; nil for tests and previews, which keep them in memory.
    private let draftsURL: URL?
    /// Every draft write, in order, off the main thread.
    private let draftQueue = DispatchQueue(label: "Sundown Drafts", qos: .utility)
    private static let hostsKey = "sundown.hosts.v1"
    private static let windowKey = "sundown.window.v1"
    private static let appearanceKey = "sundown.appearance.v1"
    private static let alertsKey = "sundown.alerts.v1"
    /// `didSet` runs while `load()` restores values; saving then would write half-restored state.
    private var isLoading = false
    private var connectedAll = false
    /// Hosts no window showed when the app connected, connected once those that did are up.
    @ObservationIgnored private(set) var waitingHosts: Set<UUID> = []

    /// How many windows show each thread: a followed thread is let go only when none does.
    @ObservationIgnored private var viewers: [ObjectIdentifier: Int] = [:]

    /// Hosts' environment values, by host id. The Keychain for the app's own defaults; anything
    /// with its own defaults (tests, previews, UI tests) keeps them in memory instead.
    private let secrets: SecretStore
    /// What each host's environment was when last written, so saving doesn't touch the Keychain
    /// for every change of selection.
    private var writtenEnv: [UUID: [String: String]] = [:]
    /// The hosts whose environment values are in the Keychain, as the store says (`environmentHosts`):
    /// only these are read, and a host with none never asks it anything.
    @ObservationIgnored private var keychainHosts: Set<UUID> = []
    /// The one read of those values, started as the first host connects.
    @ObservationIgnored private var environmentLoad: Task<Void, Never>?

    public convenience init(defaults: UserDefaults = .standard) {
        let standard = defaults === UserDefaults.standard
        self.init(defaults: defaults, secrets: standard ? KeychainSecrets() : DefaultsSecrets(defaults),
                  draftsURL: standard ? Self.standardDraftsURL : nil)
    }

    init(defaults: UserDefaults, secrets: SecretStore, draftsURL: URL? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        self.draftsURL = draftsURL
        let held = draftsURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        drafts = held
        writtenDrafts = held
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
        let first = shown.compactMap { connections[$0] }.map(connectOnceEnvironmentIsRead)
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
        for id in waiting { if let c = connections[id] { _ = connectOnceEnvironmentIsRead(c) } }
    }

    /// A window shows `id`: it doesn't wait for the others.
    private func connectIfWaiting(_ id: UUID) {
        guard waitingHosts.remove(id) != nil, let c = connections[id] else { return }
        _ = connectOnceEnvironmentIsRead(c)
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
        guard let i = hosts.firstIndex(where: { $0.id == h.id }), hosts[i] != h else { return }
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
        keychainHosts.remove(id)
        waitingHosts.remove(id)
        pinnedChats[id] = nil
        if let c = connections.removeValue(forKey: id) { Task { await c.disconnect() } }
        if lastHostID == id {
            lastHostID = HostConfig.local.id
            lastThreadID = nil
            saveWindow()
        }
        for window in openWindows { window.hostRemoved(id) }
        save()
    }

    /// Connects `c` once the hosts' environment values are read, since `initialize` sends them.
    private func connectOnceEnvironmentIsRead(_ c: HostConnection) -> Task<Void, Never> {
        Task { await environmentLoaded(); await c.connect() }
    }

    /// Returns once the Keychain's values for the hosts that have some are in `hosts`: read off the
    /// main thread, once, as the first host connects. Settings shows them, and `initialize` sends them.
    func environmentLoaded() async {
        if environmentLoad == nil { environmentLoad = Task { await loadEnvironment() } }
        await environmentLoad?.value
    }

    private func loadEnvironment() async {
        let ids = hosts.filter { $0.env.isEmpty && keychainHosts.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        let secrets = secrets
        let values = await Task.detached(priority: .userInitiated) {
            ids.map { ($0, secrets.read($0.uuidString)) }
        }.value
        var stale = false
        for (id, data) in values {
            // A host changed in Settings meanwhile keeps what was typed.
            guard let i = hosts.firstIndex(where: { $0.id == id }), hosts[i].env.isEmpty else { continue }
            let env = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            writtenEnv[id] = env
            if env.isEmpty {
                // The store said there were values and the Keychain has none.
                keychainHosts.remove(id)
                stale = true
            } else {
                hosts[i].env = env
                connections[id]?.update(host: hosts[i])
            }
        }
        if stale { save() }
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
        if lastHostID != window.hostID || lastThreadID != window.threadID {
            lastHostID = window.hostID
            lastThreadID = window.threadID
            saveWindow()
        }
        connectIfWaiting(window.hostID)
    }

    /// A window started showing `thread`.
    func retain(_ thread: ThreadModel?) {
        guard let thread else { return }
        viewers[ObjectIdentifier(thread), default: 0] += 1
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

    /// Kept at once, written once typing pauses: encoding every draft into a file on each keystroke
    /// was most of what typing cost.
    public func setDraft(_ text: String, for threadID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : text
        guard drafts[threadID] != next else { return }
        drafts[threadID] = next
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

    /// The drafts to write now and where, unless the file already holds them: a save with nothing
    /// new, or typing that came back to what was written, writes nothing.
    private func draftsToWrite() -> (drafts: [String: String], url: URL)? {
        draftsSave?.cancel()
        draftsSave = nil
        guard let draftsURL, drafts != writtenDrafts else { return nil }
        writtenDrafts = drafts
        return (drafts, draftsURL)
    }

    /// Writes the drafts in the background if they changed: encoded and written off the main
    /// thread, after any write before it.
    private func writeDrafts() {
        guard let (drafts, url) = draftsToWrite() else { return }
        draftQueue.async { Self.write(drafts, to: url) }
    }

    /// Writes the drafts now, rather than when typing pauses, and waits: at quit.
    public func saveDrafts() {
        guard let (drafts, url) = draftsToWrite() else { return }
        draftQueue.sync { Self.write(drafts, to: url) }
    }

    /// Returns once the drafts' background writes so far are done.
    func waitForDraftWrites() { draftQueue.sync {} }

    /// A deleted chat's draft goes with it.
    public func forgetDraft(for threadID: String) {
        guard drafts.removeValue(forKey: threadID) != nil else { return }
        writeDrafts()
    }

    /// `Drafts.json` in the app's Application Support directory: a pasted prompt can be long, and
    /// the defaults file is rewritten whole.
    private static var standardDraftsURL: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "Sundown", directoryHint: .isDirectory)
            .appending(path: "Drafts.json")
    }

    private nonisolated static func write(_ drafts: [String: String], to url: URL) {
        let encoder = JSONEncoder()
        // Sorted keys, so the same drafts are the same bytes.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(drafts) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: persistence

    // Everything but `hosts` is optional, so a store written by an older build still decodes.
    private struct Stored: Codable {
        var hosts: [HostConfig]
        var transcriptWidth: String?
        var sidebarGrouping: String?
        var textScale: Double?
        var sidebarFilter: String?
        /// By host id.
        var pinnedChats: [String: [String]]?
        /// The hosts whose environment values are in the Keychain.
        var environmentHosts: [String]?
    }

    /// Where the most recently used window was, under a key of its own: it changes with every chat
    /// switch, and with the rest it wrote the hosts, pins and preferences again
    /// each time.
    private struct LastWindow: Codable {
        var hostID: UUID?
        var threadID: String?
    }

    /// Sorted keys, so the same values are the same bytes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let stored = defaults.data(forKey: Self.hostsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        hosts = stored?.hosts ?? []
        if !hosts.contains(where: { $0.id == HostConfig.local.id }) { hosts.insert(.local, at: 0) }
        // Their values are read from the Keychain as the first host connects (`environmentLoaded`).
        keychainHosts = Set((stored?.environmentHosts ?? []).compactMap(UUID.init(uuidString:)))
        appearance = defaults.data(forKey: Self.appearanceKey)
            .flatMap { try? JSONDecoder().decode(Appearance.self, from: $0) } ?? Appearance()
        alerts = defaults.data(forKey: Self.alertsKey)
            .flatMap { try? JSONDecoder().decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        if let s = stored {
            transcriptWidth = s.transcriptWidth.flatMap(TranscriptWidth.init(rawValue:)) ?? .narrow
            sidebarGrouping = s.sidebarGrouping.flatMap(SidebarGrouping.init(rawValue:)) ?? .date
            textScale = s.textScale.map { CGFloat($0) } ?? 1
            sidebarFilter = s.sidebarFilter.flatMap(SidebarFilter.init(rawValue:)) ?? .all
            for (host, ids) in s.pinnedChats ?? [:] {
                if let id = UUID(uuidString: host), !ids.isEmpty { pinnedChats[id] = Set(ids) }
            }
        }
        let window = defaults.data(forKey: Self.windowKey).flatMap { try? JSONDecoder().decode(LastWindow.self, from: $0) }
        // A remembered host can disappear between launches; this Mac is always configured.
        if let id = window?.hostID, hosts.contains(where: { $0.id == id }) {
            lastHostID = id
            lastThreadID = window?.threadID
        }
    }

    private func save() {
        guard !isLoading else { return }
        for host in hosts where writtenEnv[host.id] ?? [:] != host.env {
            if secrets.write(host.env.isEmpty ? nil : try? JSONEncoder().encode(host.env), for: host.id.uuidString) {
                writtenEnv[host.id] = host.env
                if host.env.isEmpty { keychainHosts.remove(host.id) } else { keychainHosts.insert(host.id) }
            }
        }
        // The defaults file keeps everything but the values, unless the Keychain refused them: then
        // they stay inline, as a store from before the Keychain has them, until a save gets them there.
        let hosts = hosts.map { host in
            var h = host
            if writtenEnv[host.id] ?? [:] == host.env { h.env = [:] }
            return h
        }
        let s = Stored(hosts: hosts, transcriptWidth: transcriptWidth.rawValue,
                       sidebarGrouping: sidebarGrouping.rawValue, textScale: Double(textScale),
                       sidebarFilter: sidebarFilter.rawValue,
                       pinnedChats: Dictionary(uniqueKeysWithValues: pinnedChats.map { ($0.key.uuidString, $0.value.sorted()) }),
                       environmentHosts: self.hosts.filter { keychainHosts.contains($0.id) }.map(\.id.uuidString))
        defaults.set(try? Self.encoder.encode(s), forKey: Self.hostsKey)
    }

    private func saveWindow() {
        guard !isLoading else { return }
        let window = LastWindow(hostID: lastHostID, threadID: lastThreadID)
        defaults.set(try? Self.encoder.encode(window), forKey: Self.windowKey)
    }
}

/// Resumes a continuation once, whichever of its callers comes first.
private final class ResumeOnce: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { if $0 { return false }; $0 = true; return true } }
}

extension AppModel {
    /// The launch's first window shows `threadID`, whether it's restored or new: the debug-only
    /// `SUNDOWN_OPEN_THREAD` launch hook.
    public func openOnLaunch(threadID: String, on host: UUID) {
        lastHostID = host
        lastThreadID = threadID
        launchChat = (host, threadID)
    }
}

extension AppModel {
    /// The launched XCTest app uses the real UI and reducer with only in-process transports. In
    /// every build (the performance tests run against Release), used only with SUNDOWN_UI_TEST_MODE.
    public static func uiTestFixture() -> AppModel {
        // The README's screenshots: one host, as most people have, so no host name in the subtitle.
        let showcase = ProcessInfo.processInfo.environment["SUNDOWN_UI_TEST_SCENARIO"] == "showcase"
        let ssh = HostConfig(name: "Fixture SSH", kind: .ssh(destination: "fixture.invalid"))
        // A fresh store each launch, unless a test that relaunches names one to keep.
        let suite = ProcessInfo.processInfo.environment["SUNDOWN_UI_TEST_DEFAULTS"]
        let local = UITestFixture.launchConnection(host: .local)
        let app = sample(connections: showcase ? [local] : [local, UITestFixture.launchConnection(host: ssh)],
                         defaults: suite.flatMap(UserDefaults.init(suiteName:)))
        // The first window opens on the fixture's chat, or where the kept store says it was.
        if app.lastThreadID == nil { app.lastThreadID = showcase ? UITestFixture.showcaseThreadID : UITestFixture.threadID }
        return app
    }

    /// Pre-seeded hosts and connections for `#Preview`s and tests, off persistence and the network.
    public static func sample(connections: [HostConnection], defaults: UserDefaults? = nil) -> AppModel {
        let app = AppModel(defaults: defaults ?? UserDefaults(suiteName: "sundown.preview.\(UUID().uuidString)") ?? .standard)
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
