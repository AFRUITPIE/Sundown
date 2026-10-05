import Foundation
import Observation
import TetherProtocol

/// A chat being started from New Chat (`HostConnection.prepareStart`), from Send until the host has
/// started it and its first prompt is in. `thread/start` is sent as it always was; only what the
/// window shows meanwhile is new: `placeholder`, a model of the window's own holding the prompt as
/// it was sent and saying Starting Session. The placeholder is never one of the host's chats: it
/// isn't in `HostConnection`'s threads, gets no sequence numbers, is never subscribed, and nothing
/// but the window that sent it shows it. The host's chat is its own model, made as any other is
/// (often by the notifications that come before the answer), and the window moves to it once its
/// prompt's echo is there (`isReady`), so the two are never on screen together.
@MainActor
@Observable
public final class PendingStart: Identifiable {
    public nonisolated let id: UUID
    public let hostID: UUID
    public let cwd: String
    public let input: [UserInput]
    /// The settings it was started with. What's changed in New Chat's menus meanwhile is applied
    /// to the chat once it has started.
    public let options: NewThreadOptions
    /// What the window that sent it shows until the chat has started.
    public let placeholder: ThreadModel
    /// The prompt in `placeholder`.
    public let promptID: String

    /// How the start came out: the host's chat, or why there isn't one.
    public private(set) var result: Result<ThreadModel, any Error>?
    /// The host's chat shows the prompt as the host echoed it (`echoID`), or, without an echo,
    /// enough of the chat to take the placeholder's place. Set only after `result` is a success.
    public private(set) var isReady = false
    /// The echo of the prompt sent, in the host's chat: the prompt the window already showed, so
    /// it isn't shown arriving again.
    public private(set) var echoID: String?
    /// Stop was pressed before the host answered: the chat is interrupted once it has started.
    @ObservationIgnored var interruptRequested = false

    @ObservationIgnored private var startWaiters: [CheckedContinuation<Result<ThreadModel, any Error>, Never>] = []
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    init(hostID: UUID, cwd: String, input: [UserInput], options: NewThreadOptions, defaults: SessionDefaultsResult?) {
        let id = UUID()
        self.id = id
        self.hostID = hostID
        self.cwd = cwd
        self.input = input
        self.options = options
        let placeholder = ThreadModel(id: "starting-\(id.uuidString.lowercased())")
        let promptID = "\(placeholder.id)-prompt"
        placeholder.beginStarting(
            info: ThreadInfo(threadId: placeholder.id, status: .running, cwd: cwd,
                             model: options.model ?? defaults?.model,
                             effort: options.effort ?? defaults?.effort,
                             permissionMode: options.permissionMode ?? defaults?.permissionMode,
                             fastModeState: options.fastMode == true ? "on" : nil, lastSeq: 0),
            prompt: .userMessage(.init(id: promptID, createdAt: Date().timeIntervalSince1970 * 1000,
                                       content: input)))
        self.placeholder = placeholder
        self.promptID = promptID
    }

    /// The host's chat, once there is one.
    public var thread: ThreadModel? {
        if case .success(let thread)? = result { thread } else { nil }
    }

    /// The host's chat, once it has started; throws why it didn't.
    public func started() async throws -> ThreadModel {
        if let result { return try result.get() }
        return try await withCheckedContinuation { startWaiters.append($0) }.get()
    }

    /// Returns once the window can move to the host's chat (`isReady`), or the start has failed.
    public func ready() async {
        if isReady || isFailed { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private var isFailed: Bool {
        if case .failure? = result { true } else { false }
    }

    func resolve(_ result: Result<ThreadModel, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        placeholder.endStarting()
        for waiter in startWaiters { waiter.resume(returning: result) }
        startWaiters = []
        if case .failure = result { resumeReady() }
    }

    func markReady(echo: String?) {
        guard !isReady, thread != nil else { return }
        echoID = echo
        isReady = true
        resumeReady()
    }

    private func resumeReady() {
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters = []
    }

    /// Whether the host's chat shows enough to take the placeholder's place, and its echo of the
    /// prompt if it has one. The first prompt a person sent in it is the echo when it says what was
    /// sent. Without one, a turn that has ended, or a chat that has closed, will do.
    func readiness(of chat: ThreadModel) -> (ready: Bool, echo: String?) {
        let first = chat.items.lazy.compactMap { item -> Item.UserMessage? in
            guard case .userMessage(let m) = item, m.parentToolUseId == nil, m.synthetic != true, m.origin == nil else { return nil }
            return m
        }.first
        if let first { return (true, Self.says(first.content, as: input) ? first.id : nil) }
        let ended = chat.turns.contains { $0.status != .inProgress } || chat.status == .closed
        return (ended, nil)
    }

    /// Whether an echoed prompt says what was sent: the same words, or, for a prompt with none, the
    /// same number of attachments.
    static func says(_ echoed: [UserInput], as sent: [UserInput]) -> Bool {
        func words(_ parts: [UserInput]) -> String {
            parts.compactMap { if case .text(let t) = $0 { t.text } else { nil } }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sentWords = words(sent)
        guard sentWords.isEmpty else { return words(echoed) == sentWords }
        return echoed.count == sent.count
    }
}

#if DEBUG
extension PendingStart {
    /// A chat just sent from New Chat, before the host has answered, for `#Preview`s.
    public static func sample(_ prompt: String = "Tidy up the build scripts and make the release one runnable locally.",
                              cwd: String = "/Users/hayden/Code/tether-app") -> PendingStart {
        let op = PendingStart(hostID: HostConfig.local.id, cwd: cwd, input: [.text(.init(text: prompt))], options: .init(), defaults: nil)
        op.placeholder.settleArrivals()
        return op
    }
}
#endif
