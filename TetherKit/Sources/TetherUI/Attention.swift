import AppKit
import SwiftUI
import TetherKit
import TetherProtocol
import UserNotifications

/// Settings ▸ Notifications (persisted by `AppModel`).
public struct AlertPreferences: Codable, Equatable, Sendable {
    public var replyFinished: When = .inBackground
    public var needsInput = true
    public var sound = true
    public var dockBadge: DockBadge = .waiting

    public init() {}

    public enum When: String, Codable, CaseIterable, Identifiable, Sendable {
        case never, inBackground, always
        public var id: Self { self }
        var label: String {
            switch self {
            case .never: "Never"
            case .inBackground: "When I’m Not Looking at It"
            case .always: "Always"
            }
        }
    }

    public enum DockBadge: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, waiting, working
        public var id: Self { self }
        var label: String {
            switch self {
            case .off: "Nothing"
            case .waiting: "Chats Waiting on You"
            case .working: "Chats Claude Is Working In"
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertPreferences()
        replyFinished = (try? c.decodeIfPresent(When.self, forKey: .replyFinished)) ?? d.replyFinished
        needsInput = (try? c.decodeIfPresent(Bool.self, forKey: .needsInput)) ?? d.needsInput
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? d.sound
        dockBadge = (try? c.decodeIfPresent(DockBadge.self, forKey: .dockBadge)) ?? d.dockBadge
    }
}

/// The requests already told about. The daemon re-sends a request that's still waiting on every
/// reconnect, and each would otherwise post its notification, with its sound, again.
struct RequestSightings {
    private var seen: Set<String> = []
    private var order: [String] = []
    /// How many are remembered; a request waits minutes, not hundreds of reconnects.
    static let limit = 500

    /// True the first time `id` is seen.
    mutating func firstSighting(of id: String) -> Bool {
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > Self.limit { seen.remove(order.removeFirst()) }
        return true
    }
}

/// What happened in a chat that might be worth telling someone who isn't looking at it.
enum AttentionEvent: Equatable {
    case replyFinished(failed: Bool)
    case needsInput
}

/// Tells people what their chats need while they're elsewhere: a notification when a reply
/// finishes or Claude asks for something, the Dock badge, and the Dock menu. Clicking a
/// notification opens its chat; a permission request's notification can be answered from it.
@MainActor
final class AttentionCenter: NSObject {
    private unowned let app: AppModel
    /// In UI tests nothing reaches Notification Center; what would have is kept here instead.
    private let deliversToSystem: Bool
    private(set) var delivered: [(title: String, body: String)] = []
    private var authorization: UNAuthorizationStatus?
    private var sightings = RequestSightings()

    init(app: AppModel, deliversToSystem: Bool) {
        self.app = app
        self.deliversToSystem = deliversToSystem
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: .tetherTurnFinished, object: nil, queue: .main) { [weak self] note in
            let info = Info(note)
            MainActor.assumeIsolated { self?.turnFinished(info) }
        }
        center.addObserver(forName: .tetherNeedsAttention, object: nil, queue: .main) { [weak self] note in
            let info = Info(note)
            MainActor.assumeIsolated { self?.needsInput(info) }
        }
        center.addObserver(forName: .tetherRequestResolved, object: nil, queue: .main) { [weak self] note in
            let info = Info(note)
            MainActor.assumeIsolated { self?.requestResolved(info) }
        }
        if deliversToSystem {
            let notifications = UNUserNotificationCenter.current()
            notifications.delegate = self
            notifications.setNotificationCategories([Self.permissionCategory])
        }
        trackBadge()
    }

    /// What the notification carried, copied out of it on the posting thread.
    private struct Info: @unchecked Sendable {
        let connection: HostConnection?
        let threadID: String?
        let requestID: String?
        let status: String?

        init(_ note: Notification) {
            connection = note.object as? HostConnection
            threadID = note.userInfo?["threadId"] as? String
            requestID = note.userInfo?["requestId"] as? String
            status = note.userInfo?["status"] as? String
        }
    }

    // MARK: deciding

    /// Whether `event` in a chat is worth a notification: never for a chat on screen in the app
    /// you're using, and otherwise as Settings ▸ Notifications says.
    nonisolated static func shouldNotify(_ event: AttentionEvent, prefs: AlertPreferences, appIsActive: Bool, chatIsShown: Bool) -> Bool {
        let looking = appIsActive && chatIsShown
        switch event {
        case .needsInput:
            return prefs.needsInput && !looking
        case .replyFinished:
            switch prefs.replyFinished {
            case .never: return false
            case .inBackground: return !looking
            case .always: return true
            }
        }
    }

    /// Whether a window in front shows the chat.
    private func isShown(_ thread: ThreadModel) -> Bool {
        app.openWindows.contains { $0.selectedThread === thread && ($0.isKey || app.openWindows.count == 1) }
    }

    private func turnFinished(_ info: Info) {
        guard let connection = info.connection, let id = info.threadID else { return }
        let thread = connection.thread(id)
        let failed = info.status == TurnStatus.failed.rawValue
        // A turn you stopped isn't news.
        guard info.status != TurnStatus.interrupted.rawValue else { return }
        guard Self.shouldNotify(.replyFinished(failed: failed), prefs: app.alerts, appIsActive: app.isActive, chatIsShown: isShown(thread)) else {
            // In front of you: no notification, but VoiceOver hears that the reply is done.
            if isShown(thread) { announce(failed ? "Claude couldn’t finish." : "Claude finished.") }
            return
        }
        post(id: "turn-\(id)", title: thread.title, body: failed ? "Claude couldn’t finish." : Self.lastReplyLine(thread),
             host: connection.id, threadID: id)
    }

    private func needsInput(_ info: Info) {
        guard let connection = info.connection, let id = info.threadID else { return }
        // Once per request, not again each time a reconnect re-sends it.
        if let requestID = info.requestID, !sightings.firstSighting(of: "\(connection.id)/\(requestID)") { return }
        let thread = connection.thread(id)
        let request = thread.pending.first { $0.id == info.requestID }?.request
        // On screen, the request's card takes VoiceOver's focus and reads its heading; said here
        // too, it was heard twice.
        guard Self.shouldNotify(.needsInput, prefs: app.alerts, appIsActive: app.isActive, chatIsShown: isShown(thread)) else {
            return
        }
        post(id: "request-\(info.requestID ?? id)", title: thread.title, body: Self.describe(request),
             host: connection.id, threadID: id, requestID: info.requestID,
             category: request.map { if case .permissionRequest = $0 { true } else { false } } == true ? Self.permissionCategory.identifier : nil)
    }

    /// A request was answered, here or elsewhere, or cancelled: its notification goes.
    private func requestResolved(_ info: Info) {
        guard deliversToSystem, let requestID = info.requestID else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["request-\(requestID)"])
        center.removePendingNotificationRequests(withIdentifiers: ["request-\(requestID)"])
    }

    /// Whether the request is still waiting for an answer.
    private func isWaiting(host: UUID, threadID: String, requestID: String) -> Bool {
        app.connection(host)?.thread(threadID).pending.contains { $0.id == requestID } == true
    }

    /// The reply's last line, as a notification's body shows it.
    static func lastReplyLine(_ thread: ThreadModel) -> String {
        for item in thread.items.reversed() {
            if case .agentMessage(let m) = item, !m.text.isEmpty {
                let plain = MarkdownView.plainText(m.text).trimmingCharacters(in: .whitespacesAndNewlines)
                let line = plain.split(separator: "\n").last.map(String.init) ?? plain
                return line.count > 160 ? String(line.prefix(157)) + "…" : line
            }
        }
        return "Claude finished."
    }

    static func describe(_ request: ServerRequest?) -> String {
        switch request {
        case .permissionRequest(let p): p.title ?? "Allow \(p.displayName ?? p.toolName)?"
        case .questionRequest: "Claude has a question for you."
        case .planApprove: "Claude has a plan ready for you to review."
        case .elicitationRequest: "An MCP server needs your input."
        default: "Claude needs your input."
        }
    }

    /// Spoken by VoiceOver, for a reply finishing in the chat on screen while the reader is
    /// elsewhere in it: after whatever is being read, not over it.
    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    // MARK: delivering

    private static let permissionCategory = UNNotificationCategory(
        identifier: "permission",
        actions: [
            UNNotificationAction(identifier: "allow", title: "Allow"),
            UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
        ],
        intentIdentifiers: [])

    private func post(id: String, title: String, body: String, host: UUID, threadID: String,
                      requestID: String? = nil, category: String? = nil) {
        guard deliversToSystem else {
            delivered.append((title, body))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if app.alerts.sound { content.sound = .default }
        content.threadIdentifier = threadID
        if let category { content.categoryIdentifier = category }
        var info: [String: String] = ["host": host.uuidString, "thread": threadID]
        if let requestID { info["request"] = requestID }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            guard await authorize() else { return }
            // Answered while permission was being asked for: nothing to say any more.
            if let requestID, !isWaiting(host: host, threadID: threadID, requestID: requestID) { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Allow or Deny on a request that was answered elsewhere, or cancelled, since its notification
    /// went up: says so in its place, quietly, rather than doing nothing.
    private func sayAlreadyAnswered(id: String, title: String, threadID: String, host: UUID) {
        guard deliversToSystem else {
            delivered.append((title, Self.alreadyAnswered))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Self.alreadyAnswered
        content.threadIdentifier = threadID
        content.interruptionLevel = .passive
        content.userInfo = ["host": host.uuidString, "thread": threadID]
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
    }

    static let alreadyAnswered = "Already answered."


    /// Asked the first time there's something to say, not at launch.
    private func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        authorization = status
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorization = granted ? .authorized : .denied
            return granted
        }
        return status == .authorized || status == .provisional
    }

    /// Whether notifications are turned off for Tether in System Settings.
    func systemDenied() async -> Bool {
        guard deliversToSystem else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Opens the chat a notification is about.
    func open(host: UUID, threadID: String) {
        app.open(.chat(host: host, thread: threadID))
    }

    // MARK: Dock

    /// The chats the Dock badge counts, as Settings ▸ Notifications ▸ Dock Badge chooses.
    nonisolated static func badgeCount(_ threads: [(isRunning: Bool, waiting: Bool)], badge: AlertPreferences.DockBadge) -> Int {
        switch badge {
        case .off: 0
        case .waiting: threads.filter(\.waiting).count
        case .working: threads.filter(\.isRunning).count
        }
    }

    private var allChats: [ThreadModel] {
        app.connections.values.flatMap(\.chats)
    }

    private func trackBadge() {
        let count = withObservationTracking {
            Self.badgeCount(allChats.map { ($0.isRunning, !$0.pending.isEmpty || $0.status == .requiresAction) },
                            badge: app.alerts.dockBadge)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackBadge() }
        }
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    /// The Dock icon's menu: chats waiting on you, then chats Claude is working in, then New Chat.
    /// SwiftUI's own menu content, hosted where AppKit asks for a menu.
    func dockMenu() -> NSMenu {
        NSHostingMenu(rootView: DockMenu(app: app))
    }
}

/// The Dock menu's items, each a `tether://` link the app routes to a window.
private struct DockMenu: View {
    let app: AppModel

    var body: some View {
        let chats = app.connections.values.flatMap { c in c.chats.map { (connection: c, thread: $0) } }
        let waiting = chats.filter { !$0.thread.pending.isEmpty || $0.thread.status == .requiresAction }
        let working = chats.filter { $0.thread.isRunning && $0.thread.pending.isEmpty && $0.thread.status != .requiresAction }
        section("Waiting on You", waiting)
        section("Working", working)
        Button("New Chat") { app.open(.newChat()) }
    }

    @ViewBuilder
    private func section(_ title: String, _ chats: [(connection: HostConnection, thread: ThreadModel)]) -> some View {
        if !chats.isEmpty {
            Section(title) {
                ForEach(chats.prefix(8), id: \.thread.id) { chat in
                    Button(chat.thread.title) { app.open(.chat(host: chat.connection.id, thread: chat.thread.id)) }
                }
            }
        }
    }
}

extension AttentionCenter: UNUserNotificationCenterDelegate {
    /// A notification the app decided to post shows even while it's frontmost: it was only posted
    /// because the chat isn't the one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let hostString = info["host"] as? String, let host = UUID(uuidString: hostString),
              let threadID = info["thread"] as? String else { return }
        let requestID = info["request"] as? String
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        let title = response.notification.request.content.title
        await MainActor.run {
            switch action {
            case "allow", "deny":
                let thread = app.connection(host)?.thread(threadID)
                guard let thread, let pending = thread.pending.first(where: { $0.id == requestID }) else {
                    sayAlreadyAnswered(id: identifier, title: thread?.title ?? title, threadID: threadID, host: host)
                    return
                }
                thread.answer(pending, with: action == "allow"
                    ? ["decision": "allow", "scope": "once"]
                    : ["decision": "deny", "message": "The user denied this action."])
            default:
                open(host: host, threadID: threadID)
            }
        }
    }
}

/// The app's delegate, for what SwiftUI has no scene API for: the Dock icon's menu, and a window
/// when the system's restoration brings back none.
@MainActor
public final class TetherAppDelegate: NSObject, NSApplicationDelegate {
    public weak var app: AppModel?
    private var openWindow: ((WindowTarget) -> Void)?

    /// Called from the app's body, before any window exists.
    public func install(app: AppModel, openWindow: @escaping (WindowTarget) -> Void) {
        guard self.app == nil else { return }
        self.app = app
        self.openWindow = openWindow
    }

    /// A launch whose restored state has no windows — after a crash, or a quit with every window
    /// closed — opens one anyway. SwiftUI's `defaultLaunchBehavior(.presented)` applies only when
    /// there's no state to restore at all.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishRestoringWindowsNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openWindowIfNone() }
        }
    }

    private func openWindowIfNone() {
        guard let app, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        openWindow?(app.newWindowTarget())
    }

    /// Hosts connect, and notifications and the Dock badge start, with the app rather than its first
    /// chat window.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        app?.isActive = NSApp.isActive
        app?.startAttention()
        app?.connectAll()
    }

    /// Whether another app is in front, which decides whether a chat on screen is being looked at.
    public func applicationDidBecomeActive(_ notification: Notification) { app?.isActive = true }
    public func applicationDidResignActive(_ notification: Notification) { app?.isActive = false }

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        app?.dockMenu()
    }
}
