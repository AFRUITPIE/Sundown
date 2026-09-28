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
    /// Whether chats started or resumed here get the session tools (Settings ▸ General).
    public var offersSessionTools = false
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
    /// Failed attempts in a row, for `ReconnectBackoff`.
    @ObservationIgnored private(set) var reconnectAttempt = 0
    /// The wait before the next attempt, cancelled by one that starts sooner.
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Whether the last failure is worth trying again: a protocol mismatch isn't, until one side
    /// is updated.
    @ObservationIgnored private var retryable = true
    /// Nil for the test seam, whose hosts don't wait for the network.
    @ObservationIgnored private let network: NetworkPath?
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
        self.network = .shared
        NetworkPath.shared.watch(self)
    }

    /// Test seam for reconnect/replay coverage. `network` is the path a test drives; without one
    /// the host never waits for the network.
    init(host: HostConfig, network: NetworkPath? = nil, transportProvider: @escaping TransportProvider) {
        self.host = host
        self.id = host.id
        self.transportProvider = transportProvider
        self.network = network
        network?.watch(self)
    }

    public func update(host: HostConfig) {
        let needsReconnect = host.kind != self.host.kind || host.env != self.host.env || host.serverCommand != self.host.serverCommand
        self.host = host
        if needsReconnect, wantsConnection { Task { await reconnect() } }
    }

    // MARK: connection lifecycle

    /// Connects if it isn't, and returns once it is, or once the attempt fails: for work asked of a
    /// host before it's up, such as a Shortcut that launches the app to start a chat.
    public func connected() async -> Bool {
        if case .connected = state { return true }
        if case .connecting = state {
            while case .connecting = state {
                // Woken by the next change of state, not by polling it.
                await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = self.state } onChange: { resume.resume() }
                }
            }
        } else {
            await connect()
        }
        if case .connected = state { return true }
        return false
    }

    public func connect() async {
        wantsConnection = true
        if case .connected = state { return }
        if case .connecting = state { return }
        state = .connecting("Starting…")
        do {
            // UI tests must never fall through to the bundled daemon or SSH, even if a
            // screen creates another host while the fixture app is running.
            if ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1", transportProvider == nil {
                throw TransportError.launchFailed("UI test host has no fixture transport")
            }
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
            retryable = !(error is Incompatible)
            if retryable { scheduleReconnect() }
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
        reconnectTask?.cancel()
        reconnectTask = nil
        await tearDown()
        state = .disconnected
    }

    /// Asked for: the backoff starts over.
    public func reconnect() async {
        reconnectAttempt = 0
        await disconnect()
        await connect()
    }

    /// Tries a dropped connection again now, with the backoff started over: the Mac woke, or
    /// someone asked. Nothing for a connection that's up, under way, or not wanted.
    public func retryNow() {
        reconnectAttempt = 0
        guard wantsConnection, retryable, case .failed = state else { return }
        if needsNetwork, network?.isSatisfied == false { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.connect() }
    }

    /// The network came back, or moved to another interface: an SSH host is worth trying again.
    func networkChanged() {
        guard needsNetwork else { return }
        retryNow()
    }

    /// Only an SSH host needs the network; this Mac's daemon is a process away.
    private var needsNetwork: Bool { host.sshDestination != nil }

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

    /// Tries again after `ReconnectBackoff`'s wait, or, for an SSH host while the Mac is off the
    /// network, once the network is back (`networkChanged`) rather than on a timer.
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        if needsNetwork, network?.isSatisfied == false {
            appendLog("Waiting for the network")
            return
        }
        reconnectAttempt += 1
        let delay = ReconnectBackoff.delay(afterFailures: reconnectAttempt, jitter: .random(in: 0..<1))
        appendLog("Trying again in \(delay.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
        reconnectTask = Task { [weak self] in
            // Some slack, so the wake can share one with other timers.
            try? await Task.sleep(for: delay, tolerance: delay / 10)
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
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
        // Answered here, by another client, or cancelled: a notification about it is out of date.
        if case .serverRequestResolved(let e) = n {
            NotificationCenter.default.post(name: .tetherRequestResolved, object: self,
                                            userInfo: ["threadId": tid, "requestId": e.requestId])
        }
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
            input: input.isEmpty ? nil : input,
            worktree: options.worktree ? true : nil,
            sessionTools: offersSessionTools ? true : nil))
        let model = thread(r.thread.threadId)
        model.setInfo(r.thread)
        model.loadHistory(items: model.items, turns: model.turns, seq: nil)
        subscribed.insert(model.id)
        // In a worktree the chat's folder is the worktree's, not the one chosen.
        attach(model, toProject: r.thread.cwd)
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
            threadId: model.id, sessionTools: offersSessionTools ? true : nil, cwd: model.cwd,
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

    /// A question about the chat, answered with its context but kept out of it (the CLI's /btw).
    public func sideQuestion(_ model: ThreadModel, _ question: String) async throws -> String? {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        try await makeLive(model, client)
        return try await client.call(Methods.ThreadSideQuestion.self, .init(threadId: model.id, question: question)).answer
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
        model.sentAt = Date()
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

    /// Archive keeps a chat but out of the sidebar's list, as the session's tag: nothing is deleted.
    public func setArchived(_ model: ThreadModel, _ archived: Bool) async {
        await perform(model) { try await $0.call(Methods.ThreadTag.self, .init(threadId: model.id, tag: archived ? ThreadModel.archivedTag : nil)) }
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

    /// Everything that differs from the last commit in `cwd`: staged and unstaged edits, and new
    /// files git doesn't track yet (their whole content, as added). Nil when `cwd` isn't a repository.
    public func workingChanges(cwd: String) async throws -> WorkingChanges? {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        let status = try await client.call(Methods.GitStatus.self, .init(cwd: cwd))
        guard status.isRepo else { return nil }
        async let unstaged = client.call(Methods.GitDiff.self, .init(cwd: cwd))
        async let staged = client.call(Methods.GitDiff.self, .init(cwd: cwd, staged: true))
        var untracked: [(path: String, content: String?)] = []
        for file in status.files where file.status == "??" && !file.path.hasSuffix("/") {
            let full = (cwd as NSString).appendingPathComponent(file.path)
            let read = try? await client.call(Methods.FsRead.self, .init(path: full, maxBytes: 64 * 1024))
            untracked.append((file.path, read.flatMap { $0.encoding == .utf8 ? $0.content : nil }))
        }
        let stagedDiff = try await staged.diff, unstagedDiff = try await unstaged.diff
        let files = await UnifiedDiff.workingTree(staged: stagedDiff, unstaged: unstagedDiff, untracked: untracked)
        return WorkingChanges(branch: status.branchName, files: files)
    }

    /// Whether `cwd` is in a git repository and what is checked out there (`branchName`), for New
    /// Chat. Nil when the host couldn't say.
    public func gitStatus(cwd: String) async -> GitStatusResult? {
        try? await client?.call(Methods.GitStatus.self, .init(cwd: cwd))
    }

    /// Removes a worktree Tether made for a chat, and its branch. Throws `RPCError.worktreeDirty`
    /// when it has uncommitted changes, unless `force`, and `RPCError.worktreeUnmerged` when its
    /// branch has commits merged nowhere else, unless `discardCommits`.
    public func removeWorktree(_ path: String, force: Bool, discardCommits: Bool) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        _ = try await client.call(Methods.GitRemoveWorktree.self, .init(path: path, force: force, discardCommits: discardCommits))
    }

    // MARK: plugins

    /// Installed plugins, and the ones the host's marketplaces offer. `cwd` adds a project's.
    public func plugins(cwd: String?) async throws -> PluginCatalog {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        let r = try await client.call(Methods.PluginList.self, .init(cwd: cwd))
        return PluginCatalog(installed: r.installed.compactMap(InstalledPlugin.init), available: r.available.compactMap(AvailablePlugin.init))
    }

    public func installPlugin(_ id: String, scope: PluginInstallParams.Scope, cwd: String?) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        _ = try await client.call(Methods.PluginInstall.self, .init(pluginId: id, scope: scope, cwd: cwd))
    }

    public func uninstallPlugin(_ plugin: InstalledPlugin, cwd: String?) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        _ = try await client.call(Methods.PluginUninstall.self, .init(pluginId: plugin.id, scope: plugin.scope.map { .init(rawValue: $0) }, cwd: cwd))
    }

    public func setPlugin(_ plugin: InstalledPlugin, enabled: Bool, cwd: String?) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        _ = try await client.call(Methods.PluginSetEnabled.self, .init(pluginId: plugin.id, enabled: enabled, scope: plugin.scope.map { .init(rawValue: $0) }, cwd: cwd))
    }

    // MARK: scheduled tasks

    /// The daemon's scheduled tasks on this host.
    public func scheduledTasks() async throws -> [ScheduledTask] {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        return try await client.call(Methods.ScheduleList.self, .init()).tasks
    }

    @discardableResult
    public func saveScheduledTask(_ params: ScheduleSaveParams) async throws -> ScheduledTask {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        return try await client.call(Methods.ScheduleSave.self, params).task
    }

    public func deleteScheduledTask(_ id: String) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        _ = try await client.call(Methods.ScheduleDelete.self, .init(id: id))
    }

    /// Runs a task now; the chat it started, which the chat list shows once it's refreshed.
    public func runScheduledTask(_ id: String) async throws -> String {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        let threadID = try await client.call(Methods.ScheduleRun.self, .init(id: id)).threadId
        await loadChats()
        return threadID
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
    /// Start in a new git worktree of the folder's repository.
    public var worktree = false
    public init(model: String? = nil, effort: EffortLevel? = nil, permissionMode: PermissionMode? = nil, fastMode: Bool? = nil,
                worktree: Bool = false) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.fastMode = fastMode
        self.worktree = worktree
    }
}

public struct PluginCatalog: Sendable, Equatable {
    public let installed: [InstalledPlugin]
    public let available: [AvailablePlugin]

    public init(installed: [InstalledPlugin], available: [AvailablePlugin]) {
        self.installed = installed
        self.available = available
    }
}

/// A plugin as `claude plugin list --json` reports it: `name@marketplace`, where it's installed, on or off.
public struct InstalledPlugin: Identifiable, Sendable, Equatable {
    public let id: String
    public let version: String?
    public let scope: String?
    public let enabled: Bool
    public var name: String { String(id.split(separator: "@").first ?? Substring(id)) }
    public var marketplace: String? { id.split(separator: "@").dropFirst().first.map(String.init) }

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        version = json["version"]?.stringValue
        scope = json["scope"]?.stringValue
        enabled = json["enabled"]?.boolValue ?? true
    }
}

/// A plugin a marketplace offers.
public struct AvailablePlugin: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let marketplace: String?
    public let installCount: Int?

    public init?(_ json: JSONValue) {
        guard let id = json["pluginId"]?.stringValue else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        description = json["description"]?.stringValue ?? ""
        marketplace = json["marketplaceName"]?.stringValue
        installCount = json["installCount"]?.intValue
    }
}

extension GitStatusResult {
    /// The branch from the header of `git status -b`, which the daemon passes on as git wrote it:
    /// "main", "No commits yet on main" in a new repository, and "HEAD (no branch)" when detached,
    /// which has no branch to name.
    public var branchName: String? {
        guard isRepo, let branch, !branch.isEmpty, branch != "HEAD (no branch)" else { return nil }
        for prefix in ["No commits yet on ", "Initial commit on "] where branch.hasPrefix(prefix) {
            return String(branch.dropFirst(prefix.count))
        }
        return branch
    }
}

public struct WorkingChanges: Sendable, Equatable {
    public let branch: String?
    public let files: [FileDiff]
    /// Summed once, not per draw.
    public let added: Int
    public let removed: Int

    public init(branch: String?, files: [FileDiff]) {
        self.branch = branch
        self.files = files
        added = files.reduce(0) { $0 + $1.added }
        removed = files.reduce(0) { $0 + $1.removed }
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
    /// `HostConnection`; `threadId` and `requestId` are in the user info. Posted again for the same
    /// request each time the daemon re-sends it, as it does on every reconnect.
    public static let tetherNeedsAttention = Notification.Name("TetherNeedsAttention")
    /// Posted when a turn ends, as it arrives live (not replayed). The object is the
    /// `HostConnection`; `threadId` and the turn's `status` are in the user info.
    public static let tetherTurnFinished = Notification.Name("TetherTurnFinished")
    /// Posted when a request no longer needs an answer: answered by any client, or cancelled. The
    /// object is the `HostConnection`; `threadId` and `requestId` are in the user info.
    public static let tetherRequestResolved = Notification.Name("TetherRequestResolved")
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
