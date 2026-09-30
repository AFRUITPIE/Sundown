import Testing
import TetherProtocol
@testable import TetherKit
@testable import TetherUI

/// Sending moves no row between the transcript's lazy stack and its eager tail: moved into the lazy
/// stack, rows were counted at guessed heights and the transcript lurched as the prompt went in.
@MainActor @Suite struct TranscriptSplitTests {
    private let folding = TranscriptFolding.summarized
    private let counter = Counter()

    private final class Counter { var seq = 0 }
    private func next() -> Int { counter.seq += 1; return counter.seq }

    private func split(_ thread: ThreadModel) -> Int {
        TranscriptView.split(thread.rows(folding), prompts: thread.prompts(folding),
                             running: (thread.isRunning || thread.currentTurn != nil) && !thread.awaitingPrompt)
    }

    /// A settled chat of short turns: a prompt and a reply each.
    private func chat(turns: Int) -> ThreadModel {
        let thread = ThreadModel(id: "chat")
        for t in 0..<turns { send(t, to: thread, reply: true, statusFirst: false, check: nil) }
        return thread
    }

    /// One turn as the host sends it, checking the split after every notification.
    private func send(_ t: Int, to thread: ThreadModel, reply: Bool, statusFirst: Bool, check: ((ThreadModel) -> Void)?) {
        let turn = Turn(id: "t\(t)", status: .inProgress, startedAt: 0)
        var steps: [ServerNotification] = [
            .turnStarted(.init(threadId: "chat", seq: next(), turn: turn)),
            .itemStarted(.init(threadId: "chat", seq: next(), item: .userMessage(.init(
                id: "p\(t)", createdAt: 0, content: [.text(.init(text: "Prompt \(t)"))])))),
        ]
        let running = ServerNotification.threadStatusChanged(.init(threadId: "chat", seq: next(), status: .running))
        if statusFirst { steps.insert(running, at: 0) } else { steps.append(running) }
        for step in steps { thread.apply(step); check?(thread) }
        guard reply else { return }
        var done = turn
        done.status = .completed
        thread.apply(.itemStarted(.init(threadId: "chat", seq: next(), item: .agentMessage(.init(id: "r\(t)", createdAt: 0, text: "Reply \(t)")))))
        thread.apply(.turnCompleted(.init(threadId: "chat", seq: next(), turn: done)))
        thread.apply(.threadStatusChanged(.init(threadId: "chat", seq: next(), status: .idle)))
    }

    @Test(arguments: [false, true])
    func sendingKeepsTheSplit(statusFirst: Bool) {
        let thread = chat(turns: 6)
        let before = split(thread)
        send(6, to: thread, reply: false, statusFirst: statusFirst) { thread in
            #expect(self.split(thread) == before)
        }
    }

    @Test func aLongSettledTurnKeepsOnlyItsTail() {
        let thread = chat(turns: 2)
        send(2, to: thread, reply: false, statusFirst: false, check: nil)
        for i in 0..<20 {
            thread.apply(.itemStarted(.init(threadId: "chat", seq: next(), item: .agentMessage(.init(id: "n\(i)", createdAt: 0, text: "Note \(i)")))))
            thread.apply(.itemCompleted(.init(threadId: "chat", seq: next(), item: .agentMessage(.init(id: "n\(i)", createdAt: 0, text: "Note \(i)")))))
        }
        thread.apply(.turnCompleted(.init(threadId: "chat", seq: next(), turn: .init(id: "t2", status: .completed, startedAt: 0))))
        thread.apply(.threadStatusChanged(.init(threadId: "chat", seq: next(), status: .idle)))
        #expect(split(thread) == thread.rows(folding).count - TranscriptView.eagerTailLimit)
    }

    @Test func onlyALivePromptArrives() {
        let thread = chat(turns: 1)
        #expect(thread.arrivedPrompt == "p0")
        #expect(!thread.awaitingPrompt)
        thread.apply(.turnStarted(.init(threadId: "chat", seq: next(), turn: .init(id: "t1", status: .inProgress, startedAt: 0))))
        #expect(thread.awaitingPrompt)
        thread.loadHistory(items: thread.items, turns: thread.turns, seq: nil)
        #expect(!thread.awaitingPrompt)
        #expect(thread.arrivedPrompt == "p0")
    }
}
