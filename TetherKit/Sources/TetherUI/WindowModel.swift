import Foundation
import Observation
import SwiftUI
import TetherKit
import TetherProtocol

/// What a window shows: a host, and a chat on it or New Chat. The window's scene value: each window
/// keeps it current (`WindowRoot`), so the system restores each window to it, and opening a chat
/// with `openWindow(value:)` brings forward the window already showing that chat. Two windows on
/// New Chat are different windows, so without a chat a target is equal only to itself (`id`).
public struct WindowTarget: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var threadID: String?
    /// Tells apart windows that show no chat.
    public var id: UUID

    public init(hostID: UUID, threadID: String? = nil, id: UUID = UUID()) {
        self.hostID = hostID
        self.threadID = threadID
        self.id = id
    }

    /// A value saved before `id` existed still restores its window.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    }

    public static func == (a: Self, b: Self) -> Bool {
        if let thread = a.threadID { return thread == b.threadID && a.hostID == b.hostID }
        return b.threadID == nil && a.id == b.id
    }

    public func hash(into hasher: inout Hasher) {
        if let threadID {
            hasher.combine(hostID)
            hasher.combine(threadID)
        } else {
            hasher.combine(id)
        }
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
    /// The task the Tasks pane has open, wherever the inspector is.
    public var inspectedTaskID: String?

    /// Whether the inspector is showing for this window, wherever Settings ▸ Advanced ▸ Inspector
    /// puts it: the floating panel is the app's, one for every window; the other placements are
    /// each window's own.
    public var inspectorShown: Bool {
        get { app.appearance.inspector == .panel ? app.inspectorPanelShown : showInspector }
        set {
            if app.appearance.inspector == .panel { app.inspectorPanelShown = newValue } else { showInspector = newValue }
        }
    }

    /// The New Chat screen's session controls, reset to the defaults by `newChat()`.
    public var draftModel: String?
    public var draftEffort: EffortLevel?
    public var draftPermissionMode: PermissionMode = .default
    /// Carried into `startThread`; off unless the user asks for it on this chat.
    public var draftFastMode = false
    /// Start the chat in a new git worktree, so it doesn't share a checkout with other chats.
    public var draftWorktree = false
    /// The New Chat folder: the host's most recent project until one is chosen, nil before the
    /// projects arrive.
    public var draftDirectory: String?
    /// Why the New Chat draft couldn't start, cleared with the draft.
    var draftError: String?

    /// Find in Chat for this window's transcript.
    public let find = TranscriptFind()
    /// Chat ▸ Previous Prompt and Next Prompt, for this window's transcript.
    public let prompts = PromptNavigator()

    /// The chat Rename… or Delete… is acting on, from the Chat menu or a sidebar row's context menu.
    public private(set) var renaming: ThreadModel?
    public var deleting: ThreadModel?
    /// Starts a task Claude suggested in `thread` as a new chat, where it said, or in `thread`'s folder.
    /// Opens a task Claude suggested as New Chat, in the folder it named (or `thread`'s), with its
    /// prompt as a draft to read and edit before sending: Claude wrote it, so it isn't sent unseen.
    func startSuggestedTask(_ task: SuggestedTask, from thread: ThreadModel) {
        thread.dismissSuggestedTask(task.id)
        newChat()
        draftDirectory = task.cwd ?? thread.cwd
        app.deliverDraft(task.prompt, for: "new-chat:\(hostID)")
    }

    /// Chat ▸ Ask a Side Question… (⌥⌘;) is showing its sheet.
    var askingSideQuestion = false

    /// A worktree to offer removing, once the chat that worked in it is archived or deleted, and
    /// what removing it would lose that the host asked about.
    var worktreeToRemove: WorktreeRemoval?
    /// Why removing a worktree failed, for its alert.
    var worktreeError: String?

    struct WorktreeRemoval: Equatable {
        let path: String
        /// Discard uncommitted changes: the host said there are some, and the second ask was answered.
        var force = false
        /// Delete the branch's commits that are merged nowhere else, likewise.
        var discardCommits = false
    }

    /// After archiving or deleting `thread`: if it worked in a worktree Tether made, offer to remove it.
    func offerWorktreeRemoval(for thread: ThreadModel) {
        guard let root = thread.cwd.flatMap(Self.tetherWorktree) else { return }
        worktreeToRemove = WorktreeRemoval(path: root)
    }

    /// The worktree `cwd` is in, when Tether made it: `<repo>/.claude/worktrees/tether-<8 hex>`. The
    /// chat may work in a subfolder of it; Claude Desktop's worktrees, beside Tether's, aren't ours.
    static func tetherWorktree(_ cwd: String) -> String? {
        guard let marker = cwd.range(of: "/.claude/worktrees/") else { return nil }
        let name = cwd[marker.upperBound...].split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard name.wholeMatch(of: /tether-[0-9a-f]{8}/) != nil else { return nil }
        return String(cwd[..<marker.upperBound]) + name
    }

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

    /// Opens on `target`. Reads nothing off `app`: a window's model is made in its view's
    /// initializer, which runs again whenever the scene's content does; `start()` finishes the job.
    public init(app: AppModel, target: WindowTarget) {
        self.app = app
        self.hostID = target.hostID
        self.threadID = target.threadID
        self.showInspector = false
        self.inspectorPane = .tasks
    }

    /// Shows the chat and seeds the draft. Called once the window is on screen, with the inspector
    /// as the window had it (restored), or as the most recently used window had it (a new window).
    public func start(inspector: (shown: Bool, pane: InspectorPane)? = nil) {
        guard !started else { return }
        // A remembered host can disappear between launches; this Mac is always configured.
        if app.connections[hostID] == nil && !app.hosts.contains(where: { $0.id == hostID }) {
            hostID = HostConfig.local.id
        }
        let inspector = inspector ?? (app.lastShowInspector, app.lastInspectorPane)
        showInspector = inspector.shown
        inspectorPane = inspector.pane
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

    /// What the window shows, as its scene value: `id` keeps a window on New Chat itself.
    public func target(keeping id: UUID) -> WindowTarget { WindowTarget(hostID: hostID, threadID: threadID, id: id) }

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
    public func isInspecting(_ pane: InspectorPane) -> Bool { inspectorShown && inspectorPane == pane }

    /// Shows `pane`, opening the inspector if it is closed.
    public func openInspector(on pane: InspectorPane) {
        if inspectorPane != pane { inspectorPane = pane }
        if !inspectorShown { inspectorShown = true }
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

    /// A link routed to this window: a chat to show, or New Chat — the Dock menu's, or Shortcuts'
    /// Start a Chat on this Mac, in `folder` if given, with `prompt` in the field, or sent when
    /// there's a folder to start in.
    public func handle(_ link: TetherLink) async {
        switch link {
        case .chat(let host, let thread):
            open(threadID: thread, on: host)
        case .newChat(let host, let folder, let prompt, let sendToken):
            if let host, host != hostID { hostID = host }
            newChat()
            if let folder, !folder.isEmpty { draftDirectory = (folder as NSString).expandingTildeInPath }
            let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            if TetherLink.redeem(sendToken), draftDirectory != nil {
                await startDraftChat([.text(.init(text: text))])
            } else {
                app.deliverDraft(text, for: "new-chat:\(hostID)")
            }
        }
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
        draftWorktree = app.appearance.worktreeByDefault
        draftDirectory = app.appearance.newChatFolder == .recent ? app.connections[hostID]?.projects.first?.cwd : nil
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
        guard let cwd = draftDirectory else { draftError = "Choose a directory first."; return }
        draftError = nil
        do {
            let t = try await connection.startThread(cwd: cwd, input: input,
                                                     options: .init(model: draftModel, effort: draftEffort,
                                                                    permissionMode: draftPermissionMode, fastMode: draftFastMode,
                                                                    worktree: draftWorktree))
            open(threadID: t.id, on: connection.id)
        } catch {
            draftError = error.localizedDescription
        }
    }
}

extension WindowModel {
    /// The chats the sidebar lists: those View ▸ Show includes, and the open one whatever it says.
    var sidebarThreads: [ThreadModel] {
        let filter = app.sidebarFilter
        return (connection?.chats ?? []).filter { filter.includes($0) || $0 === selectedThread }
    }

    /// The sidebar's sections for this window's host, in its layout (Settings' unless given), pins
    /// and grouping. Reads only what doesn't change while a turn streams: title, folder, timestamp,
    /// tag, status and requests.
    func sidebarList(_ threads: [ThreadModel], style: Appearance.SidebarStyle? = nil, search: String = "") -> [SidebarSection] {
        let pins = app.pinnedChats[hostID] ?? []
        let chats = threads.map {
            SidebarChat(id: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: $0.summary?.updatedAt,
                        isPinned: pins.contains($0.id), isArchived: $0.isArchived,
                        needsYou: !$0.pending.isEmpty || $0.status == .requiresAction)
        }
        return sidebarSections(chats: chats, grouping: app.sidebarGrouping, style: style ?? app.appearance.sidebar, search: search)
    }

    public func isPinned(_ thread: ThreadModel) -> Bool { app.isPinned(thread.id, on: hostID) }

    /// Chat ▸ Pin or Unpin.
    public func togglePin(_ thread: ThreadModel) {
        app.setPinned(!isPinned(thread), thread.id, on: hostID)
    }

    /// Archives or unarchives chats on this window's host; nothing is deleted. Leaves a chat being
    /// archived for New Chat, and offers to remove the worktree of the one chat archived on its own.
    func setArchived(_ threads: [ThreadModel], _ archived: Bool) {
        guard let connection, !threads.isEmpty else { return }
        if archived, let open = selectedThread, threads.contains(where: { $0 === open }) { newChat() }
        Task { for thread in threads { await connection.setArchived(thread, archived) } }
        if archived, threads.count == 1 { offerWorktreeRemoval(for: threads[0]) }
    }

    /// The chat above or below this one in the sidebar's order (Chat ▸ Next Chat, ⌥⌘]); from New
    /// Chat, the first. Wraps at the ends, as moving between tabs does.
    func adjacentChat(_ offset: Int) -> String? {
        let order = sidebarList(sidebarThreads).flatMap { $0.chats.map(\.id) }
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
