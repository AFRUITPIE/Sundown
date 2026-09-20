import Foundation
import Observation
import TetherProtocol

/// Live connection to one host's Tether daemon, plus that host's projects and threads.
@MainActor
@Observable
public final class HostConnection: Identifiable {
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

    public init(host: HostConfig) {
        self.host = host
        self.id = host.id
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
            let boot = HostBootstrapper(log: { [weak self] m in Task { @MainActor in self?.appendLog(m); self?.state = .connecting(m) } })
            let cmd = try await boot.connectCommand(for: host)
            appendLog("$ \(([cmd.executable] + cmd.arguments).joined(separator: " "))")
            let transport = ProcessTransport(executable: cmd.executable, arguments: cmd.arguments)
            let client = RPCClient(transport: transport)
            self.client = client
            await client.setServerRequestHandler { [weak self] req in await self?.handleServerRequest(req) }
            await client.onClose { [weak self] error in
                Task { @MainActor in self?.connectionLost(error) }
            }
            startNotificationPump(client)
            await client.start()
            state = .connecting("Handshaking…")
            let initResult = try await client.call(Methods.Initialize.self, .init(
                clientInfo: .init(name: "tether-app", title: "Tether", version: "0.1.0"),
                capabilities: .init(experimentalApi: true),
                env: host.env.isEmpty ? nil : host.env))
            try await client.notify("initialized")
            serverInfo = initResult
            appendLog("Connected: \(initResult.host.hostname), claude \(initResult.claude.version) at \(initResult.claude.path)")
            state = .connected
            reconnectAttempt = 0
            await resubscribeAll()
            await openRequestedThreads()
            await refreshCatalog()
        } catch {
            appendLog("Connection failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    public func disconnect() async {
        wantsConnection = false
        notificationTask?.cancel()
        await client?.close()
        client = nil
        subscribed.removeAll()
        for t in threads.values { t.clearPending() }
        state = .disconnected
    }

    public func reconnect() async {
        await disconnect()
        await connect()
    }

    private func connectionLost(_ error: any Error) {
        guard client != nil else { return }
        client = nil
        subscribed.removeAll()
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        bufferedDeltas.removeAll()
        notificationTask?.cancel()
        for t in threads.values { t.clearPending() }
        appendLog("Disconnected: \(error.localizedDescription)")
        state = .failed(error.localizedDescription)
        scheduleReconnect()
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
            // Partial messages arrive per token. Applying each one separately redraws the
            // transcript at the model's typing speed, so they're batched into a frame.
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
        model.apply(n)
        if case .threadStarted(let e) = n, let cwd = Optional(e.thread.cwd) { attach(model, toProject: cwd) }
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

    /// After reconnecting, catch every loaded thread up from its last seen seq (the daemon kept running).
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

    /// Load any thread that was requested via `open(_:)` while we weren't connected yet
    /// (selected on launch before `connect()` finished, or during a reconnect).
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
            NotificationCenter.default.post(name: .tetherNeedsAttention, object: nil, userInfo: ["threadId": tid])
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

    /// Open a thread: loads history and, if it is live in the daemon, subscribes to it.
    /// If we're not connected yet (e.g. the thread was selected on launch, before `connect()`
    /// finished, or while reconnecting), defer instead of failing: `connect()` will load it via
    /// `openRequestedThreads()` once it succeeds.
    public func open(_ model: ThreadModel) async {
        openRequested.insert(model.id)
        guard case .connected = state else { return }
        await loadRequestedThread(model)
    }

    private func loadRequestedThread(_ model: ThreadModel) async {
        do {
            try await loadHistory(model, force: false)
            model.setError(nil) // clear a stale "Not connected" from an earlier attempt
        } catch {
            model.setError(error.localizedDescription)
        }
    }

    private func loadHistory(_ model: ThreadModel, force: Bool) async throws {
        guard let client else { throw RPCError(code: -1, message: "Not connected") }
        if model.historyLoaded && !force { return }
        let r = try await client.call(Methods.ThreadRead.self, .init(threadId: model.id, cwd: model.cwd))
        if let s = r.summary { model.setSummary(s) }
        model.loadHistory(items: r.items, turns: r.turns, seq: r.historySeq)
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

    public func send(_ model: ThreadModel, input: [UserInput]) async {
        guard let client else { model.setError("Not connected"); return }
        do {
            if !subscribed.contains(model.id) {
                // Not loaded in the daemon yet: resume (server replays nothing; we already have history).
                let r = try await client.call(Methods.ThreadResume.self, .init(threadId: model.id, cwd: model.cwd, afterSeq: nil, includeHistory: true))
                model.loadHistory(items: r.items ?? model.items, turns: r.turns ?? model.turns, seq: r.historySeq)
                model.setInfo(r.thread)
                subscribed.insert(model.id)
            }
            _ = try await client.call(Methods.TurnStart.self, .init(threadId: model.id, input: input))
            model.setError(nil)
        } catch {
            model.setError(error.localizedDescription)
        }
    }

    public func interrupt(_ model: ThreadModel) async {
        _ = try? await client?.call(Methods.TurnInterrupt.self, .init(threadId: model.id))
    }

    public func setModel(_ model: ThreadModel, _ value: String?) async {
        await perform(model) { try await $0.call(Methods.ThreadSetModel.self, .init(threadId: model.id, model: value)) }
    }

    public func setEffort(_ model: ThreadModel, _ value: EffortLevel?) async {
        await perform(model) { try await $0.call(Methods.ThreadSetEffort.self, .init(threadId: model.id, effort: value)) }
    }

    public func setPermissionMode(_ model: ThreadModel, _ value: PermissionMode) async {
        await perform(model) { try await $0.call(Methods.ThreadSetPermissionMode.self, .init(threadId: model.id, mode: value)) }
    }

    public func setFastMode(_ model: ThreadModel, _ on: Bool) async {
        await perform(model) { try await $0.call(Methods.ThreadSetFastMode.self, .init(threadId: model.id, enabled: on)) }
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

    public func contextUsage(_ model: ThreadModel) async -> JSONValue? {
        try? await client?.call(Methods.ThreadContextUsage.self, .init(threadId: model.id, detail: .summary)).usage
    }

    public func commands(for model: ThreadModel) async -> [SlashCommand] {
        (try? await client?.call(Methods.CommandList.self, .init(cwd: model.cwd, threadId: subscribed.contains(model.id) ? model.id : nil)).commands) ?? []
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

extension Notification.Name {
    /// Posted when a thread needs user input (approval, question, plan).
    public static let tetherNeedsAttention = Notification.Name("TetherNeedsAttention")
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

#if DEBUG
extension HostConnection {
    /// Seeds this connection's in-memory state for `#Preview`s. Never touches the network, spawns
    /// a process, or calls a real daemon — the `private(set)` properties above can only be written
    /// from within this file, so `PreviewSupport.swift` calls through to this instead of duplicating them.
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
