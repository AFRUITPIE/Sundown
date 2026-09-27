import Foundation
import Observation
import TetherProtocol

/// Live connection to one host's Tether daemon, plus that host's projects and threads.
@MainActor
@Observable
public final class HostConnection: Identifiable {
    typealias TransportProvider = @Sendable (HostConfig) async throws -> any Transport
    public enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected
        case failed(String)
    }

    public private(set) var host: HostConfig
    public nonisolated let id: UUID
    public private(set) var state: State = .disconnected
    public private(set) var serverInfo: InitializeResult?
    public private(set) var account: AccountInfo?
    public private(set) var models: [ModelInfo] = []
    public private(set) var projects: [ProjectListResult.Project] = []
    /// All chats on this host, most recent first (across every directory).
    public private(set) var chats: [ThreadModel] = []
    public private(set) var log: [String] = []

    private var threads: [String: ThreadModel] = [:]
    private var client: RPCClient?
    private var notificationTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var wantsConnection = false
    private var subscribed = Set<String>()
    /// Threads a view has asked to open, whether or not we were connected at the time.
    private var openRequested = Set<String>()
    private var bufferedDeltas: [ServerNotification] = []
    private var deltaFlushTask: Task<Void, Never>?
    private var chatsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let transportProvider: TransportProvider?

    /// Reported to the daemon on connect.
    static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    public init(host: HostConfig) {
        self.host = host
        self.id = host.id
        self.transportProvider = nil
    }

    /// Test seam for reconnect/replay coverage.
    init(host: HostConfig, transportProvider: @escaping TransportProvider) {
        self.host = host
        self.id = host.id
        self.transportProvider = transportProvider
    }

    public func update(host: HostConfig) {
        let needsReconnect = host.kind != self.host.kind || host.env != self.host.env || host.serverCommand != self.host.serverCommand
        self.host = host
        if needsReconnect, wantsConnection { Task { await reconnect() } }
    }

    // MARK: connection lifecycle

    public func connect() async {
        wantsConnection = true
        if case .connected = state { return }
        if case .connecting = state { return }
        state = .connecting("Starting…")
        do {
            #if DEBUG
            // UI tests must never fall through to the bundled daemon or SSH, even if a
            // screen creates another host while the fixture app is running.
            if ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1", transportProvider == nil {
                throw TransportError.launchFailed("UI test host has no fixture transport")
            }
            #endif
            let transport: any Transport
            if let transportProvider {
                transport = try await transportProvider(host)
            } else {
                let boot = HostBootstrapper(log: { [weak self] m in Task { @MainActor in self?.appendLog(m); self?.state = .connecting(m) } })
                let cmd = try await boot.connectCommand(for: host)
                appendLog("$ \(([cmd.executable] + cmd.arguments).joined(separator: " "))")
                transport = ProcessTransport(executable: cmd.executable, arguments: cmd.arguments)
            }
            let client = RPCClient(transport: transport)
            self.client = client
            await client.setServerRequestHandler { [weak self] req in await self?.handleServerRequest(req) }
            await client.onClose { [weak self, weak client] error in
                Task { @MainActor in if let client { self?.connectionLost(client, error) } }
            }
            startNotificationPump(client)
            await client.start()
            state = .connecting("Handshaking…")
            let initResult = try await client.call(Methods.Initialize.self, .init(
                clientInfo: .init(name: "tether-app", title: "Tether", version: Self.appVersion),
                protocolVersion: tetherProtocolVersion,
                // Reasoning isn't shown, so its per-token deltas are only cost.
                capabilities: .init(experimentalApi: true, optOutNotificationMethods: ["item/reasoning/delta"]),
                env: host.env.isEmpty ? nil : host.env))
            try await client.notify("initialized")
            if initResult.protocolVersion < Self.minServerProtocol {
                throw Incompatible(message: "\(host.name) runs Tether \(initResult.serverInfo.version), which is too old for this app. Update the server there.")
            }
            serverInfo = initResult
            appendLog("Connected: \(initResult.host.hostname), claude \(initResult.claude.version) at \(initResult.claude.path)")
            state = .connected
            reconnectAttempt = 0
            await resubscribeAll()
            await openRequestedThreads()
            await refreshCatalog()
        } catch {
            var error = error
            if let e = error as? RPCError, e.code == RPCError.incompatibleProtocol {
                error = Incompatible(message: "The Tether server on \(host.name) needs a newer version of this app.")
            }
            appendLog("Connection failed: \(error.localizedDescription)")
            await tearDown()
            state = .failed(error.localizedDescription)
            // Trying again can't fix a protocol mismatch; one side has to be updated first.
            if !(error is Incompatible) { scheduleReconnect() }
        }
    }

    /// The oldest server protocol this app talks to.
    static let minServerProtocol = 1

    /// The app and the server can't talk to each other until one of them is updated.
    struct Incompatible: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    public func disconnect() async {
        wantsConnection = false
        await tearDown()
        state = .disconnected
    }

    public func reconnect() async {
        await disconnect()
        await connect()
    }

    /// Only for the client that closed: a `reconnect()` can have replaced it by the time this runs.
    private func connectionLost(_ closed: RPCClient, _ error: any Error) {
        guard client === closed else { return }
        detach()
        appendLog("Disconnected: \(error.localizedDescription)")
        state = .failed(error.localizedDescription)
        scheduleReconnect()
    }

    private func tearDown() async {
        let old = client
        detach()
        await old?.close()
    }

    private func detach() {
        client = nil
        subscribed.removeAll()
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        chatsRefreshTask?.cancel()
        chatsRefreshTask = nil
        bufferedDeltas.removeAll()
        notificationTask?.cancel()
        for t in threads.values { t.clearPending() }
    }

    private func scheduleReconnect() {
        guard wantsConnection else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.wantsConnection else { return }
            if case .failed = self.state { await self.connect() }
        }
    }

    private func startNotificationPump(_ client: RPCClient) {
        notificationTask?.cancel()
        let stream = client.notifications
        notificationTask = Task { [weak self] in
            for await n in stream {
                guard let self else { return }
                self.route(n)
            }
        }
    }

    private func route(_ n: ServerNotification) {
        guard n.threadId != nil else { return }
        switch n {
        case .itemAgentMessageDelta, .itemReasoningDelta, .itemToolCallProgress:
            // Per-token; batched into one update per frame.
            bufferedDeltas.append(n)
            scheduleDeltaFlush()
        default:
            flushDeltas() // anything else has to see the deltas that came before it
            apply(n)
        }
    }

    private func apply(_ n: ServerNotification) {
        guard let tid = n.threadId else { return }
        let model = thread(tid)
        guard model.apply(n) else { return }
        if case .threadStarted(let e) = n, let cwd = Optional(e.thread.cwd) { attach(model, toProject: cwd) }
        // Its query is gone. The next send resumes it with history rather than streaming into a
        // subscription to the process that ended.
        if case .threadClosed = n { subscribed.remove(tid) }
        // Claude's name for a session only appears in thread/list; nothing announces it.
        if case .turnCompleted(let e) = n {
            scheduleChatsRefresh()
            NotificationCenter.default.post(name: .tetherTurnFinished, object: self,
                                            userInfo: ["threadId": tid, "status": e.turn.status.rawValue])
        }
    }

    private func scheduleChatsRefresh() {
        guard chatsRefreshTask == nil else { return }
        chatsRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.chatsRefreshTask = nil
            await self.loadChats()
        }
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.deltaFlushTask = nil
            self.flushDeltas()
        }
    }

    private func flushDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !bufferedDeltas.isEmpty else { return }
        let deltas = bufferedDeltas
        bufferedDeltas.removeAll(keepingCapacity: true)
        for delta in deltas { apply(delta) }
    }

    /// After reconnecting, catch every open thread up from its last seen seq (the daemon kept running).
    private func resubscribeAll() async {
        guard let client else { return }
        for model in threads.values where model.historyLoaded {
            do {
                let r = try await client.call(Methods.ThreadSubscribe.self, .init(threadId: model.id, afterSeq: model.lastSeq))
                if r.gap || r.thread.lastSeq < model.lastSeq {
                    // Server restarted or buffer overflowed: reload the transcript.
                    try await loadHistory(model, force: true)
                } else {
                    model.setInfo(r.thread)
                }
                subscribed.insert(model.id)
            } catch let e as RPCError where e.code == RPCError.threadNotLoaded {
                // Thread was unloaded (idle eviction / daemon restart); it resumes on next send.
                model.setError(nil)
            } catch {
                appendLog("Resubscribe \(model.id) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Load threads `open(_:)` was asked for before the connection was up.
    private func openRequestedThreads() async {
        for id in openRequested {
            guard let model = threads[id], !model.historyLoaded else { continue }
            await loadRequestedThread(model)
        }
    }

    // MARK: server requests

    private func handleServerRequest(_ req: ServerRequest) async -> JSONValue? {
        guard let tid = req.threadId, let rid = req.requestId else {
            return ["decision": "deny", "behavior": "cancelled", "action": "cancel"]
        }
        let model = thread(tid)
        return await withCheckedContinuation { (cont: CheckedContinuation<JSONValue?, Never>) in
            let once = OnceFlag()
            model.addPending(PendingRequest(id: rid, request: req, respond: { value in
                if once.claim() { cont.resume(returning: value) }
            }))
            NotificationCenter.default.post(name: .tetherNeedsAttention, object: self,
                                            userInfo: ["threadId": tid, "requestId": rid])
        }
    }

    // MARK: catalog

    public func refreshCatalog() async {
        guard let client else { return }
        async let projectsR = client.call(Methods.ProjectList.self, .init(limit: 200))
        async let modelsR = client.call(Methods.ModelList.self, .init())
        async let accountR = client.call(Methods.AccountRead.self, .init())
        if let p = try? await projectsR { projects = p.projects }
        await loadChats()
        if let m = try? await modelsR { models = m.models }
        if let a = try? await accountR { account = a.account }
    }

    public func loadChats(limit: Int = 200) async {
        guard let client else { return }
        do {
            let r = try await client.call(Methods.ThreadList.self, .init(limit: limit))
            var list: [ThreadModel] = []
            for s in r.threads {
                let m = thread(s.threadId)
                m.setSummary(s)
                list.append(m)
            }
            // Keep live chats that are not persisted yet (no first message on disk).
            for m in chats where !list.contains(where: { $0 === m }) { list.insert(m, at: 0) }
            chats = list
        } catch {
            appendLog("thread/list failed: \(error.localizedDescription)")
        }
    }

    // MARK: threads

    public func thread(_ id: String) -> ThreadModel {
        if let t = threads[id] { return t }
        let t = ThreadModel(id: id)
        threads[id] = t
        return t
    }

    private func attach(_ model: ThreadModel, toProject cwd: String) {
        if !chats.contains(where: { $0 === model }) { chats.insert(model, at: 0) }
        if !projects.contains(where: { $0.cwd == cwd }) {
            projects.insert(.init(cwd: cwd, lastActivity: Date().timeIntervalSince1970 * 1000, threadCount: 1), at: 0)
        }
    }

    /// Load a thread's history and subscribe to it. Before the connection is up this defers to
    /// `connect()` rather than failing.
    public func open(_ model: ThreadModel) async {
        openRequested.insert(model.id)
        guard case .connected = state else { return }
        await loadRequestedThread(model)
    }

    /// The thread is no longer on screen. A followed one is let go: the daemon keeps a file watcher
    /// and the whole parsed transcript for each, and reopening reads it afresh. A live thread stays
    /// subscribed, which is cheap and keeps its sidebar status current.
    /// Synchronous so a quick reselect can't open the thread before this unloads it.
    public func leave(_ model: ThreadModel) {
        openRequested.remove(model.id)
        guard model.isFollowed, subscribed.contains(model.id), let client else { return }
        subscribed.remove(model.id)
        model.unload()
        Task { _ = try? await client.call(Methods.ThreadUnsubscribe.self, .init(threadId: model.id)) }
    }

    private func loadRequestedThread(_ model: ThreadModel) async {
        do {
            try await loadHistory(model, force: false)
            model.setError(nil) // clear a stale "Not connected" from an earlier attempt
        } catch {
            model.setError(error.localizedDescription)
        }
    }

    /// Transcripts load from the end, a page at a time.
    /// Kept small: a chat opens at its end, and the lazy transcript measures every loaded row above
    /// the end to get there, on every open and every resize. 150 items made switching to a long chat
    /// cost about 0.5 s of main-thread work; older items load a page at a time on scrolling up.
    public static let initialHistoryLimit = 50
    public static let olderHistoryPageSize = 50

    private func loadHistory(_ model: ThreadModel, force: Bool) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        if model.historyLoaded && !force { return }
        let r = try await client.call(Methods.ThreadRead.self, .init(
            threadId: model.id, cwd: model.cwd, limit: Self.initialHistoryLimit))
        if let s = r.summary { model.setSummary(s) }
        model.loadHistory(items: r.items, turns: r.turns, seq: r.historySeq, hasMore: r.hasMore ?? false)
        if let seq = r.historySeq {
            // Loaded in the daemon: stream everything after the snapshot.
            let sub = try await client.call(Methods.ThreadSubscribe.self, .init(threadId: model.id, afterSeq: seq))
            model.setInfo(sub.thread)
            subscribed.insert(model.id)
        }
    }

    public func startThread(cwd: String, input: [UserInput], options: NewThreadOptions) async throws -> ThreadModel {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        let r = try await client.call(Methods.ThreadStart.self, .init(
            cwd: cwd,
            model: options.model,
            effort: options.effort,
            permissionMode: options.permissionMode,
            fastMode: options.fastMode,
            additionalDirectories: options.additionalDirectories.isEmpty ? nil : options.additionalDirectories,
            input: input.isEmpty ? nil : input))
        let model = thread(r.thread.threadId)
        model.setInfo(r.thread)
        model.loadHistory(items: model.items, turns: model.turns, seq: nil)
        subscribed.insert(model.id)
        attach(model, toProject: cwd)
        return model
    }

    /// Not loaded in the daemon, or only followed: resume it there. A follower numbers its events
    /// separately, so the history is reloaded to take up the live thread's seqs.
    private func makeLive(_ model: ThreadModel, _ client: RPCClient) async throws {
        guard !subscribed.contains(model.id) || model.isFollowed else { return }
        // Resumed with what the controls show: the session's own settings, or the ones picked
        // while it wasn't loaded.
        let pending = model.takePendingSettings()
        let r = try await client.call(Methods.ThreadResume.self, .init(
            threadId: model.id, cwd: model.cwd,
            model: pending.model ?? model.info?.model,
            effort: pending.effort ?? model.info?.effort,
            permissionMode: pending.permissionMode ?? model.info?.permissionMode,
            includeHistory: true, limit: Self.initialHistoryLimit))
        model.loadHistory(items: r.items ?? model.items, turns: r.turns ?? model.turns,
                          seq: r.historySeq, hasMore: r.hasMore ?? false)
        model.setInfo(r.thread)
        subscribed.insert(model.id)
        try await apply(pending, to: model, over: r.thread, client)
    }

    /// What restoring the files to before a prompt would change (`dryRun`), or did change. Claude
    /// Code keeps a checkpoint of each file an edit touched, per prompt.
    public func rewindFiles(_ model: ThreadModel, to userMessageID: String, dryRun: Bool) async throws -> RewindResult {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        try await makeLive(model, client)
        let r = try await client.call(Methods.ThreadRewindFiles.self, .init(threadId: model.id, userMessageId: userMessageID, dryRun: dryRun))
        return RewindResult(r.result)
    }

    public func send(_ model: ThreadModel, input: [UserInput]) async {
        guard let client else { model.setError("Not connected"); return }
        do {
            try await makeLive(model, client)
            _ = try await client.call(Methods.TurnStart.self, .init(threadId: model.id, input: input))
            model.setError(nil)
        } catch {
            model.setError(error.localizedDescription)
        }
    }

    public func interrupt(_ model: ThreadModel) async {
        _ = try? await client?.call(Methods.TurnInterrupt.self, .init(threadId: model.id))
    }

    /// Ends a background command or agent; the CLI reports it as stopped.
    public func stopTask(_ model: ThreadModel, taskId: String) async {
        await perform(model) { try await $0.call(Methods.TaskStop.self, .init(threadId: model.id, taskId: taskId)) }
    }

    /// Lets the turn go on without a command or agent that is holding it up, like Control-B in
    /// the terminal. The CLI only knows a foreground command as a task a few seconds in.
    public func moveToBackground(_ model: ThreadModel, toolUseId: String) async {
        guard let client else { model.setError("Not connected"); return }
        do {
            let r = try await client.call(Methods.TaskBackground.self, .init(threadId: model.id, toolUseId: toolUseId))
            model.setError(r.backgrounded ? nil : "Claude Code couldn’t move that task to the background.")
        } catch {
            model.setError(error.localizedDescription)
        }
    }

    // Settings for a thread the daemon hasn't loaded are held until it resumes, rather than
    // failing with "not loaded": there is nothing there to change yet.

    public func setModel(_ model: ThreadModel, _ value: String?) async {
        guard isLoaded(model) else { return model.editPendingSettings { $0.model = .some(value) } }
        await perform(model) { try await $0.call(Methods.ThreadSetModel.self, .init(threadId: model.id, model: value)) }
    }

    public func setEffort(_ model: ThreadModel, _ value: EffortLevel?) async {
        guard isLoaded(model) else { return model.editPendingSettings { $0.effort = .some(value) } }
        await perform(model) { try await $0.call(Methods.ThreadSetEffort.self, .init(threadId: model.id, effort: value)) }
    }

    public func setPermissionMode(_ model: ThreadModel, _ value: PermissionMode) async {
        guard isLoaded(model) else { return model.editPendingSettings { $0.permissionMode = value } }
        await perform(model) { try await $0.call(Methods.ThreadSetPermissionMode.self, .init(threadId: model.id, mode: value)) }
    }

    public func setFastMode(_ model: ThreadModel, _ on: Bool) async {
        guard isLoaded(model) else { return model.editPendingSettings { $0.fastMode = on } }
        await perform(model) { try await $0.call(Methods.ThreadSetFastMode.self, .init(threadId: model.id, enabled: on)) }
    }

    /// Whatever resume didn't take: a thread that was already live ignores its settings, and
    /// fast mode isn't a resume option.
    private func apply(_ pending: PendingSettings, to model: ThreadModel, over info: ThreadInfo, _ client: RPCClient) async throws {
        if let m = pending.model, m != info.model {
            _ = try await client.call(Methods.ThreadSetModel.self, .init(threadId: model.id, model: m))
        }
        if let e = pending.effort, e != info.effort {
            _ = try await client.call(Methods.ThreadSetEffort.self, .init(threadId: model.id, effort: e))
        }
        if let p = pending.permissionMode, p != info.permissionMode {
            _ = try await client.call(Methods.ThreadSetPermissionMode.self, .init(threadId: model.id, mode: p))
        }
        if let f = pending.fastMode, f != (info.fastModeState == "on") {
            _ = try await client.call(Methods.ThreadSetFastMode.self, .init(threadId: model.id, enabled: f))
        }
    }

    public func rename(_ model: ThreadModel, _ title: String) async {
        await perform(model) { try await $0.call(Methods.ThreadRename.self, .init(threadId: model.id, title: title)) }
        await loadChats()
    }

    public func fork(_ model: ThreadModel, at messageId: String? = nil) async -> ThreadModel? {
        guard let client else { return nil }
        guard let r = try? await client.call(Methods.ThreadFork.self, .init(threadId: model.id, atMessageId: messageId)) else { return nil }
        await loadChats()
        return thread(r.threadId)
    }

    public func delete(_ model: ThreadModel) async {
        await perform(model) { try await $0.call(Methods.ThreadDelete.self, .init(threadId: model.id)) }
        chats.removeAll { $0 === model }
        threads.removeValue(forKey: model.id)
        openRequested.remove(model.id)
    }

    /// Fetch the page before the items already held, one page at a time.
    public func loadOlderHistory(_ model: ThreadModel) async {
        guard let client, model.hasMoreHistory, !model.loadingOlder else { return }
        guard let oldest = model.items.first?.id else { return }
        model.loadingOlder = true
        defer { model.loadingOlder = false }
        do {
            let r = try await client.call(Methods.ThreadRead.self, .init(
                threadId: model.id, cwd: model.cwd, limit: Self.olderHistoryPageSize, before: oldest))
            model.prependHistory(items: r.items, hasMore: r.hasMore ?? false)
        } catch {
            appendLog("Loading older history for \(model.id) failed: \(error.localizedDescription)")
        }
    }

    /// Throws so the inspector can explain a thread the daemon hasn't loaded.
    public func contextUsage(_ model: ThreadModel) async throws -> JSONValue? {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        return try await client.call(Methods.ThreadContextUsage.self, .init(threadId: model.id, detail: .summary)).usage
    }

    /// Whether the daemon has this thread live and can answer questions about it (context usage,
    /// MCP status). A followed thread is subscribed but not loaded.
    public func isLoaded(_ model: ThreadModel) -> Bool {
        subscribed.contains(model.id) && !model.isFollowed
    }

    /// Slash commands for a directory, narrowed to a thread's own set when it is loaded.
    public func commands(cwd: String?, thread: ThreadModel? = nil) async -> [SlashCommand] {
        let threadId = thread.flatMap { isLoaded($0) ? $0.id : nil }
        return (try? await client?.call(Methods.CommandList.self, .init(cwd: cwd ?? thread?.cwd, threadId: threadId)).commands) ?? []
    }

    public func searchFiles(cwd: String, query: String) async -> [String] {
        (try? await client?.call(Methods.FsSearch.self, .init(cwd: cwd, query: query, limit: 30)).paths) ?? []
    }

    public func listDirectory(_ path: String) async throws -> [FsListResult.Entry] {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        return try await client.call(Methods.FsList.self, .init(path: path)).entries
    }

    public func gitDiff(cwd: String) async -> String? {
        try? await client?.call(Methods.GitDiff.self, .init(cwd: cwd)).diff
    }

    // MARK: MCP

    /// The chat's MCP servers as Claude Code reports them now; nil if it can't be asked.
    public func mcpServers(_ model: ThreadModel) async -> [McpServerStatus]? {
        guard isLoaded(model), let client else { return nil }
        return try? await client.call(Methods.McpStatus.self, .init(threadId: model.id)).servers
    }

    public func reconnectMCP(_ model: ThreadModel, _ name: String) async {
        await perform(model) { try await $0.call(Methods.McpReconnect.self, .init(threadId: model.id, name: name)) }
    }

    public func setMCP(_ model: ThreadModel, _ name: String, enabled: Bool) async {
        await perform(model) { try await $0.call(Methods.McpToggle.self, .init(threadId: model.id, name: name, enabled: enabled)) }
    }

    private func perform(_ model: ThreadModel, _ f: (RPCClient) async throws -> some Any) async {
        guard let client else { model.setError("Not connected"); return }
        do { _ = try await f(client); model.setError(nil) } catch { model.setError(error.localizedDescription) }
    }

    private func appendLog(_ m: String) {
        log.append(m)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

public struct NewThreadOptions: Sendable {
    public var model: String?
    public var effort: EffortLevel?
    public var permissionMode: PermissionMode?
    public var fastMode: Bool?
    public var additionalDirectories: [String] = []
    public init(model: String? = nil, effort: EffortLevel? = nil, permissionMode: PermissionMode? = nil, fastMode: Bool? = nil) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.fastMode = fastMode
    }
}

/// The SDK's answer to a file rewind: whether it can, which files it changes, and how much.
public struct RewindResult: Sendable, Equatable {
    public let canRewind: Bool
    public let error: String?
    public let files: [String]
    public let insertions: Int
    public let deletions: Int

    public init(_ value: JSONValue) {
        canRewind = value["canRewind"]?.boolValue ?? false
        error = value["error"]?.stringValue
        files = value["filesChanged"]?.arrayValue?.compactMap(\.stringValue) ?? []
        insertions = value["insertions"]?.intValue ?? 0
        deletions = value["deletions"]?.intValue ?? 0
    }
}

extension Notification.Name {
    /// Posted when a thread needs user input (approval, question, plan). The object is the
    /// `HostConnection`; `threadId` and `requestId` are in the user info.
    public static let tetherNeedsAttention = Notification.Name("TetherNeedsAttention")
    /// Posted when a turn ends, as it arrives live (not replayed). The object is the
    /// `HostConnection`; `threadId` and the turn's `status` are in the user info.
    public static let tetherTurnFinished = Notification.Name("TetherTurnFinished")
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

#if DEBUG
extension HostConnection {
    /// Seeds in-memory state for `#Preview`s without touching the network.
    public func previewSeed(
        state: State = .connected,
        client: RPCClient? = nil,
        serverInfo: InitializeResult? = nil,
        account: AccountInfo? = nil,
        models: [ModelInfo] = [],
        projects: [ProjectListResult.Project] = [],
        chats: [ThreadModel] = []
    ) {
        self.state = state
        self.client = client
        self.serverInfo = serverInfo
        self.account = account
        self.models = models
        self.projects = projects
        self.chats = chats
        for chat in chats { threads[chat.id] = chat }
    }
}
#endif
