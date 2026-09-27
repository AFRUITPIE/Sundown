import Foundation
import Observation
import SwiftUI
import TetherKit
import TetherProtocol

/// What a new window opens on: a host, and a chat on it or New Chat. Codable so File ▸ New Window
/// and Open in New Window can pass it to `openWindow(value:)`, and the system can restore it.
public struct WindowTarget: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var threadID: String?

    public init(hostID: UUID, threadID: String? = nil) {
        self.hostID = hostID
        self.threadID = threadID
    }
}

/// One window's state: its host, the chat on screen (or New Chat and its draft), its inspector,
/// and the chat a sheet or alert is acting on. App-wide state — hosts, connections, preferences —
/// is on `app`. Each change is also remembered there, so a new window or the next launch opens
/// where the most recently used window left off.
@MainActor
@Observable
public final class WindowModel {
    public let app: AppModel

    /// The host the sidebar is showing. Changing it starts a new chat there.
    public var hostID: UUID {
        didSet {
            guard hostID != oldValue else { return }
            // A remembered host can disappear between launches; this Mac is always configured.
            if app.connections[hostID] == nil && !app.hosts.contains(where: { $0.id == hostID }) {
                hostID = HostConfig.local.id
            }
            threadID = nil
            seedDraft()
            app.remember(self)
        }
    }

    /// The chat on screen, or nil for New Chat.
    /// Resolved here rather than in a view body: resolving can create the thread's model.
    public var threadID: String? {
        didSet {
            // A search belongs to the chat it was typed in.
            if threadID != oldValue { find.dismiss() }
            guard started else { return }
            resolveSelection()
            app.remember(self)
        }
    }
    public private(set) var selectedThread: ThreadModel?
    /// Whether this is the key window, for deciding whether a chat is in front of you. Unobserved:
    /// nothing on screen depends on it.
    @ObservationIgnored var isKey = false
    /// Which host `selectedThread` came from, so it is let go on the right connection.
    private var selectedThreadHost: UUID?

    /// Whether the trailing inspector is shown.
    public var showInspector: Bool { didSet { app.remember(self) } }
    /// The pane the inspector shows, kept while it is closed.
    public var inspectorPane: InspectorPane { didSet { app.remember(self) } }

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

    /// Find in Chat for this window's transcript.
    public let find = TranscriptFind()

    /// The chat Rename… or Delete… is acting on, from the Chat menu or a sidebar row's context menu.
    public private(set) var renaming: ThreadModel?
    public var deleting: ThreadModel?
    /// Restore Code to Here…: the prompt whose files are being put back, and what that changes.
    var restoring: Restore?

    struct Restore {
        let thread: ThreadModel
        let messageID: String
        let result: Result<RewindResult, Error>
    }

    /// Asks Claude Code what putting the files back to before `messageID` would change, then
    /// shows that for confirmation.
    func restoreCode(before messageID: String) {
        guard let thread = selectedThread, let connection else { return }
        Task {
            do {
                let preview = try await connection.rewindFiles(thread, to: messageID, dryRun: true)
                restoring = Restore(thread: thread, messageID: messageID, result: .success(preview))
            } catch {
                restoring = Restore(thread: thread, messageID: messageID, result: .failure(error))
            }
        }
    }
    /// The Rename field's text, filled in before the alert appears so it never opens empty.
    public var renameTitle = ""

    /// Asks for a new title for `thread`.
    public func rename(_ thread: ThreadModel?) {
        renameTitle = thread?.title ?? ""
        renaming = thread
    }

    /// Whether `start()` has run: until then nothing is resolved, so making a model in a view's
    /// initializer has no side effects.
    private var started = false

    /// Opens on `target`, or where the most recently used window was.
    public init(app: AppModel, target: WindowTarget? = nil) {
        self.app = app
        let host = target?.hostID ?? app.lastHostID
        self.hostID = app.connections[host] != nil || app.hosts.contains(where: { $0.id == host }) ? host : HostConfig.local.id
        self.threadID = target == nil ? app.lastThreadID : target?.threadID
        self.showInspector = app.lastShowInspector
        self.inspectorPane = app.lastInspectorPane
    }

    /// Shows the chat and seeds the draft. Called once the window is on screen.
    public func start() {
        guard !started else { return }
        started = true
        app.register(self)
        seedDraft()
        resolveSelection()
    }

    /// The window closed: its chat is no longer on screen here.
    public func close() {
        guard started else { return }
        app.unregister(self)
        app.release(selectedThread, on: selectedThreadHost)
        selectedThread = nil
        selectedThreadHost = nil
        started = false
    }

    /// The host the sidebar is showing.
    public var host: HostConfig? { app.hosts.first { $0.id == hostID } }

    /// The connection for the host the sidebar is showing.
    public var connection: HostConnection? { app.connections[hostID] }

    /// Where Open in New Window and the window's restoration point.
    public var target: WindowTarget { WindowTarget(hostID: hostID, threadID: threadID) }

    /// The window's subtitle: the chat's folder name, or the New Chat folder's; the full path is in
    /// the Session pane, or the folder pop-up on New Chat. Prefixed with the host when there is
    /// more than one, since nothing else in the window names it.
    public var subtitle: String {
        let folder = selectedThread.map { $0.cwd } ?? draftDirectory
        let name = folder.map { ($0 as NSString).lastPathComponent } ?? ""
        guard app.hosts.count > 1, let host = host?.name else { return name }
        return name.isEmpty ? host : "\(host) · \(name)"
    }

    /// True when the inspector is open on `pane`.
    public func isInspecting(_ pane: InspectorPane) -> Bool { showInspector && inspectorPane == pane }

    /// Shows `pane`, opening the inspector if it is closed.
    public func openInspector(on pane: InspectorPane) {
        if inspectorPane != pane { inspectorPane = pane }
        if !showInspector { showInspector = true }
    }

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

    /// A host this window shows was removed: fall back to this Mac.
    func hostRemoved(_ id: UUID) {
        if hostID == id { hostID = HostConfig.local.id }
    }

    /// Picks the defaults up again after Settings changes them, if New Chat hasn't been touched.
    func seedDraft() {
        // Always a concrete model: the Settings default, else the catalog's.
        draftModel = app.defaultModel ?? app.connections[hostID]?.models.defaultValue
        draftEffort = app.defaultEffort.map(EffortLevel.init(rawValue:))
        draftPermissionMode = PermissionMode(rawValue: app.defaultPermissionMode)
        draftFastMode = false
        draftDirectory = app.connections[hostID]?.projects.first?.cwd
        draftError = nil
    }

    private func resolveSelection() {
        let previous = selectedThread
        let previousHost = selectedThreadHost
        if let id = threadID, let c = app.connections[hostID] {
            selectedThread = c.thread(id)
            selectedThreadHost = hostID
        } else {
            selectedThread = nil
            selectedThreadHost = nil
        }
        guard previous !== selectedThread else { return }
        app.retain(selectedThread)
        app.release(previous, on: previousHost)
    }
}

extension FocusedValues {
    /// The frontmost window's model, for the menu bar's commands.
    @Entry public var window: WindowModel?
}

extension WindowModel {
    /// Starts the New Chat draft as a chat with `input` as its first message, and opens it.
    func startDraftChat(_ input: [UserInput]) async {
        guard let connection else { return }
        guard let cwd = draftDirectory else { draftError = "Choose a folder first."; return }
        draftError = nil
        do {
            let t = try await connection.startThread(cwd: cwd, input: input,
                                                     options: .init(model: draftModel, effort: draftEffort,
                                                                    permissionMode: draftPermissionMode, fastMode: draftFastMode))
            open(threadID: t.id, on: connection.id)
        } catch {
            draftError = error.localizedDescription
        }
    }
}

extension WindowModel {
    /// The chat above or below this one in the sidebar's order (Chat ▸ Next Chat, ⌃⇥); from New
    /// Chat, the first. Wraps at the ends, as ⌃⇥ does between tabs.
    func adjacentChat(_ offset: Int) -> String? {
        let chats = (connection?.chats ?? []).map {
            SidebarChat(id: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: $0.summary?.updatedAt)
        }
        let order = sidebarSections(chats: chats, grouping: app.sidebarGrouping).flatMap { $0.chats.map(\.id) }
        guard !order.isEmpty else { return nil }
        guard let threadID, let i = order.firstIndex(of: threadID) else { return offset >= 0 ? order.first : order.last }
        return order[(i + offset + order.count) % order.count]
    }

    func showAdjacentChat(_ offset: Int) {
        if let id = adjacentChat(offset) { open(threadID: id) }
    }
}

#if DEBUG
extension WindowModel {
    /// A started window on `app`, showing `threadID` if given, for `#Preview`s and tests.
    public static func sample(_ app: AppModel = .sample(), threadID: String? = nil) -> WindowModel {
        let window = WindowModel(app: app, target: WindowTarget(hostID: app.lastHostID, threadID: threadID))
        window.start()
        return window
    }
}
#endif
