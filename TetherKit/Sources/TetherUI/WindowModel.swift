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

    /// A window is its own, whatever it shows: Open in New Window opens a second window on a chat
    /// already on screen. Links find the window showing their chat by `handlesExternalEvents`.
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
            leaveNewChat()
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
            // A chat on screen: a start this window was showing goes on, but the window isn't
            // taken to its chat.
            if threadID != nil { leaveNewChat() }
            guard started else { return }
            if let threadID, threadID != oldValue { Signposts.chatSwitchBegan(to: threadID) }
            resolveSelection()
            app.remember(self)
        }
    }
    public private(set) var selectedThread: ThreadModel?
    /// A chat New Chat sent and the host hasn't started yet, shown in New Chat's place (its prompt,
    /// then Starting Session) until the window moves to the chat. Only this window shows it; the
    /// window's scene value stays New Chat meanwhile.
    public internal(set) var starting: PendingStart?
    /// Bumped whenever the window leaves New Chat (a chat, another host, closing): a New Chat
    /// composer from before then is gone, so a start sent from it that fails can't put its prompt
    /// back there.
    @ObservationIgnored private var newChatVisit = 0
    /// Where a prompt sent from this window flies from and to, one per window.
    let sendGeometry = MessageSendGeometry()
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

    /// The New Chat screen's session controls, reset to the defaults by `newChat()`.
    public var draftModel: String?
    public var draftEffort: EffortLevel?
    /// Nil until one is chosen: the chat then starts in the host's own starting mode.
    public var draftPermissionMode: PermissionMode?
    /// What the host's Claude Code starts a chat with when nothing is chosen, for the draft's
    /// directory and model (`session/defaults`), so the menus can say it.
    public var draftDefaults: SessionDefaultsResult?
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
    /// The sidebar's Search Chats field has the keyboard (Edit ▸ Find ▸ Search Chats, ⌥⌘F).
    public var searchingChats = false
    /// The window's undo manager, for the chat actions Edit ▸ Undo takes back.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Chat ▸ Previous Prompt and Next Prompt, for this window's transcript.
    public let prompts = PromptNavigator()

    /// The chat Chat ▸ Rename… or Delete… is acting on (a row's context menu renames in place, and
    /// deletes through this too).
    public internal(set) var renaming: ThreadModel?
    public var deleting: ThreadModel?
    /// The chat whose sidebar row is being renamed in place (its context menu's Rename).
    var renamingInPlace: ThreadModel?
    /// Starts a task Claude suggested in `thread` as a new chat, where it said, or in `thread`'s folder.
    /// Opens a task Claude suggested as New Chat, in the folder it named (or `thread`'s), with its
    /// prompt as a draft to read and edit before sending: Claude wrote it, so it isn't sent unseen.
    func startSuggestedTask(_ task: SuggestedTask, from thread: ThreadModel) {
        thread.dismissSuggestedTask(task.id)
        newChat()
        draftDirectory = task.cwd ?? thread.cwd
        app.deliverDraft(task.prompt, for: "new-chat:\(hostID)")
    }

    /// The chat Chat ▸ Ask a Side Question… (⌥⌘;) is asking about, while its sheet is up.
    var sideQuestion: ThreadModel?

    /// A worktree to offer removing, once the chat that worked in it is archived or deleted, and
    /// what removing it would lose that the host asked about.
    var worktreeToRemove: WorktreeRemoval?
    /// Why removing a worktree failed, for its alert.
    var worktreeError: String?

    struct WorktreeRemoval: Equatable {
        let path: String
        /// A second ask, after the host said removing it would lose something.
        var losesWork: Bool { force || discardCommits }
        /// Discard uncommitted changes: the host said there are some, and the second ask was answered.
        var force = false
        /// Delete the branch's commits that are merged nowhere else, likewise.
        var discardCommits = false
    }

    /// After archiving or deleting `thread`: if it worked in a worktree Tether made, offer to remove
    /// it, unless the offer was turned off (its Don't Ask Again, or Settings ▸ General).
    func offerWorktreeRemoval(for thread: ThreadModel) {
        guard app.appearance.offersWorktreeRemoval, let root = thread.cwd.flatMap(Self.tetherWorktree) else { return }
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

    struct Restore: Identifiable {
        var id: String { messageID }
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
        // Read before anything below changes this window, which is remembered as the last used.
        let inspector = inspector ?? (app.lastShowInspector, app.lastInspectorPane)
        // The debug launch hook's chat, in the launch's first window, restored or new.
        if let chat = app.takeLaunchChat() {
            hostID = chat.host
            threadID = chat.thread
        }
        // A remembered host can disappear between launches; this Mac is always configured.
        if app.connections[hostID] == nil && !app.hosts.contains(where: { $0.id == hostID }) {
            hostID = HostConfig.local.id
        }
        showInspector = inspector.shown
        inspectorPane = inspector.pane
        started = true
        app.register(self)
        seedDraft()
        resolveSelection()
        // The launch's first window is ready now if it has no chat to load.
        if selectedThread == nil { Signposts.chatReady(nil) }
    }

    /// The window closed: its chat is no longer on screen here.
    public func close() {
        leaveNewChat()
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
    public func isInspecting(_ pane: InspectorPane) -> Bool { showInspector && inspectorPane == pane }

    /// Shows `pane`, opening the inspector if it is closed.
    /// Shows a subagent's call in the Tasks pane.
    func inspectSubagent(_ toolUseId: String) {
        inspectedTaskID = toolUseId
        openInspector(on: .tasks)
    }

    /// Branches the chat shown after `messageID`, keeping everything up to it, and shows the branch.
    func fork(at messageID: String) {
        guard let thread = selectedThread, let connection else { return }
        Task { if let fork = await connection.fork(thread, at: messageID) { open(threadID: fork.id) } }
    }

    /// The listed chat a message's session id names, or nil when this host's list doesn't have it.
    func listedChatID(_ id: String) -> String? {
        // A desktop session's id carries a prefix ("local_…"); Claude Code's own is the rest.
        let bare = id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? id
        return connection?.chats.first { $0.id == id || $0.id == bare }?.id
    }

    public func openInspector(on pane: InspectorPane) {
        if inspectorPane != pane { inspectorPane = pane }
        if !showInspector { showInspector = true }
    }

    /// Start composing a new chat on the host the sidebar is showing. A chat still starting from
    /// here goes on, to the sidebar, and the window stays on the new draft.
    public func newChat() {
        starting = nil
        threadID = nil
        seedDraft()
    }

    /// The window's title: the chat's, or, while one is starting here, its prompt.
    public var title: String {
        selectedThread?.title ?? starting?.placeholder.title ?? "New Chat"
    }

    private func leaveNewChat() {
        if starting != nil { starting = nil }
        newChatVisit &+= 1
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
            let key = "new-chat:\(hostID)"
            let sends = TetherLink.redeem(sendToken)
            // Sent once the host is connected, which it may not be yet on a launch.
            if sends, draftDirectory != nil, await connection?.connected() == true,
               await startDraftChat([.text(.init(text: text))]) {
                return
            }
            // Otherwise it waits in the field. A link from anywhere but Shortcuts never replaces
            // a draft that's already there.
            if sends || app.draft(for: key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                app.deliverDraft(text, for: key)
            }
        }
    }

    /// A host this window shows was removed: fall back to this Mac.
    func hostRemoved(_ id: UUID) {
        if hostID == id { hostID = HostConfig.local.id }
    }

    /// Picks the defaults up again after Settings changes them, if New Chat hasn't been touched.
    func seedDraft() {
        // None chosen: the host's Claude Code picks, from its own settings (`model`, `effortLevel`,
        // `permissions.defaultMode`), as an interactive session would.
        draftModel = nil
        draftEffort = nil
        draftPermissionMode = nil
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
    /// Sends New Chat's message: starts the draft as a chat with `input` as its first message, or,
    /// while a chat this window started is still starting, sends it to that chat once it has.
    ///
    /// The window shows the start at once (`starting`): the prompt flies up and "Starting Session"
    /// waits under it. Once the host has started the chat, its prompt's echo is in and the prompt
    /// here has landed, the window moves to the chat, unless it has gone elsewhere meanwhile; New
    /// Chat's menus changed meanwhile apply to the chat. A start that fails leaves the window on
    /// New Chat with the reason, its settings as they were, and returns false so the field puts the
    /// prompt and its attachments back. When the window has left New Chat since, there's no field
    /// to put them in: the text goes into New Chat's draft, if that's empty. Nothing is sent again:
    /// a connection lost meanwhile may have started the chat.
    ///
    /// True when the message is taken care of; false when the field should have it back.
    @discardableResult
    func startDraftChat(_ input: [UserInput]) async -> Bool {
        guard let connection else { return false }
        if let starting, starting.hostID == connection.id {
            return await connection.send(starting, input: input)
        }
        guard let cwd = draftDirectory else { draftError = "Choose a directory first."; return false }
        draftError = nil
        let op = connection.prepareStart(cwd: cwd, input: input,
                                         options: .init(model: draftModel, effort: draftEffort,
                                                        permissionMode: draftPermissionMode, fastMode: draftFastMode,
                                                        worktree: draftWorktree),
                                         defaults: draftDefaults)
        // Only while it's New Chat on that host, as it was a moment ago.
        if hostID == connection.id, threadID == nil { starting = op }
        let visit = newChatVisit
        let thread: ThreadModel
        do {
            thread = try await connection.start(op)
        } catch {
            if starting === op { starting = nil }
            if visit == newChatVisit, hostID == connection.id, threadID == nil {
                draftError = Self.startFailure(error)
                return false
            }
            let key = "new-chat:\(connection.id)"
            let text = input.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined(separator: "\n")
            if !text.isEmpty, app.draft(for: key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                app.deliverDraft(text, for: key)
            }
            return true
        }
        // The menus' changes so far, while the prompt lands and the echo arrives.
        var applied = op.options
        await applyDraftSettings(over: &applied, op, to: thread, via: connection)
        await op.ready()
        await sendGeometry.landed(op.promptID)
        guard starting === op else { return true }
        await applyDraftSettings(over: &applied, op, to: thread, via: connection)
        guard starting === op else { return true }
        handOff(op, to: thread)
        return true
    }

    /// Why a chat didn't start. A connection lost meanwhile leaves it unknown whether the host
    /// started it, so that says to look before sending again.
    static func startFailure(_ error: any Error) -> String {
        if case .closed? = error as? TransportError {
            return "Lost the connection before the chat started. It may have started anyway: check the sidebar before sending again."
        }
        return error.localizedDescription
    }

    /// Stop, while a chat this window started is starting: the chat is interrupted once it has.
    func stopStarting() {
        guard let starting, let connection = app.connections[starting.hostID] else { return }
        Task { await connection.interrupt(starting) }
    }

    /// What New Chat's menus say now that the chat wasn't started with, set on the chat. Only while
    /// the window still shows the start: the menus are another draft's after that.
    private func applyDraftSettings(over applied: inout NewThreadOptions, _ op: PendingStart, to thread: ThreadModel,
                                    via connection: HostConnection) async {
        guard starting === op else { return }
        if draftModel != applied.model {
            applied.model = draftModel
            await connection.setModel(thread, draftModel)
        }
        if draftEffort != applied.effort {
            applied.effort = draftEffort
            await connection.setEffort(thread, draftEffort)
        }
        if let mode = draftPermissionMode, mode != applied.permissionMode {
            applied.permissionMode = mode
            await connection.setPermissionMode(thread, mode)
        }
        if draftFastMode != (applied.fastMode ?? false) {
            applied.fastMode = draftFastMode
            await connection.setFastMode(thread, draftFastMode)
        }
    }

    /// From the start to its chat: one move, keeping the window (`WindowTarget.id`), with what was
    /// typed meanwhile as the chat's draft, and the prompt that flew here not arriving again.
    private func handOff(_ op: PendingStart, to thread: ThreadModel) {
        starting = nil
        let key = "new-chat:\(op.hostID)"
        let typed = app.draft(for: key)
        if !typed.isEmpty, app.draft(for: thread.id).isEmpty {
            app.setDraft(typed, for: thread.id)
            app.setDraft("", for: key)
        }
        sendGeometry.landedPrompt = op.echoID
        open(threadID: thread.id, on: op.hostID)
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
    /// tag, and for Activity's Needs You, status and requests. Only Activity reads those, so a chat
    /// starting or finishing a turn doesn't regroup the Chats layout.
    func sidebarList(_ threads: [ThreadModel], style: Appearance.SidebarStyle? = nil, search: String = "") -> [SidebarSection] {
        let pins = app.pinnedChats[hostID] ?? []
        let style = style ?? app.appearance.sidebar
        let activity = style == .activity
        let chats = threads.map {
            SidebarChat(id: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: $0.summary?.updatedAt,
                        isPinned: pins.contains($0.id), isArchived: $0.isArchived,
                        needsYou: activity && (!$0.pending.isEmpty || $0.status == .requiresAction))
        }
        return sidebarSections(chats: chats, grouping: app.sidebarGrouping, style: style, search: search)
    }

    public func isPinned(_ thread: ThreadModel) -> Bool { app.isPinned(thread.id, on: hostID) }

    /// Chat ▸ Pin or Unpin.
    public func togglePin(_ thread: ThreadModel) {
        setPinned(!isPinned(thread), thread, on: hostID)
    }

    /// Pins or unpins on the host the chat is on, which Edit ▸ Undo keeps to whatever the window
    /// shows by then.
    private func setPinned(_ pinned: Bool, _ thread: ThreadModel, on host: UUID) {
        app.setPinned(pinned, thread.id, on: host)
        undoManager?.registerUndo(withTarget: self) { $0.setPinned(!pinned, thread, on: host) }
        undoManager?.setActionName(pinned ? "Pin" : "Unpin")
    }

    /// Archives or unarchives chats on this window's host; nothing is deleted, and Edit ▸ Undo puts
    /// them back. Leaves a chat being archived for New Chat, and offers to remove the worktree of
    /// the one chat archived on its own.
    func setArchived(_ threads: [ThreadModel], _ archived: Bool) {
        guard let connection else { return }
        setArchived(threads, archived, via: connection)
    }

    /// On `connection`, the host the chats are on, whichever the window shows when it's undone.
    private func setArchived(_ threads: [ThreadModel], _ archived: Bool, via connection: HostConnection) {
        guard !threads.isEmpty else { return }
        if archived, connection === self.connection, let open = selectedThread, threads.contains(where: { $0 === open }) {
            newChat()
        }
        Task { for thread in threads { await connection.setArchived(thread, archived) } }
        undoManager?.registerUndo(withTarget: self) { $0.setArchived(threads, !archived, via: connection) }
        undoManager?.setActionName(archived ? "Archive" : "Unarchive")
        // Only when it's asked for, not when an undo or a redo archives it again.
        let replaying = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if archived, threads.count == 1, !replaying { offerWorktreeRemoval(for: threads[0]) }
    }

    /// Gives `thread` a new title. Edit ▸ Undo puts back a title the person gave it; a title
    /// Claude made isn't one to set, so renaming one of those can't be undone.
    func rename(_ thread: ThreadModel, to title: String) {
        guard let connection else { return }
        rename(thread, to: title, via: connection)
    }

    private func rename(_ thread: ThreadModel, to title: String, via connection: HostConnection) {
        let new = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != thread.title else { return }
        let given = thread.summary?.customTitle.flatMap { $0.isEmpty ? nil : $0 }
        Task { await connection.rename(thread, new) }
        guard let given else { return }
        undoManager?.registerUndo(withTarget: self) { $0.rename(thread, to: given, via: connection) }
        undoManager?.setActionName("Rename")
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
