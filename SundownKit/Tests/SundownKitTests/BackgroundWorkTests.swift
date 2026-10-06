import Foundation
import Testing
import TetherProtocol
@testable import SundownKit

/// A chat whose turn has ended while its background agents and commands still run is still at work.
@MainActor
@Suite
struct BackgroundWorkTests {
    private let id = "chat"

    private func summary(_ status: ThreadStatus, tasks: Int?) -> ThreadSummary {
        ThreadSummary(threadId: id, title: "Chat", updatedAt: 0, status: status, backgroundTasks: tasks)
    }

    @Test func statusSaysHowManyAreRunning() {
        let thread = ThreadModel(id: id)
        thread.apply(.threadStatusChanged(.init(threadId: id, seq: 1, status: .idle, backgroundTasks: 2)))
        #expect(thread.hasBackgroundWork)
        #expect(!thread.isRunning)
        // A status from a server too old to count leaves the count as it was.
        thread.apply(.threadStatusChanged(.init(threadId: id, seq: 2, status: .idle)))
        #expect(thread.backgroundTaskCount == 2)
        thread.apply(.threadStatusChanged(.init(threadId: id, seq: 3, status: .idle, backgroundTasks: 0)))
        #expect(!thread.hasBackgroundWork)
    }

    @Test func theChatListSaysSoForChatsNothingStreams() {
        let thread = ThreadModel(id: id)
        thread.setSummary(summary(.idle, tasks: 1))
        #expect(thread.hasBackgroundWork)
        // Unloaded by the daemon, it runs nothing.
        thread.setSummary(summary(.notLoaded, tasks: nil))
        #expect(!thread.hasBackgroundWork)
    }

    @Test func theProcessEndingEndsThem() {
        let thread = ThreadModel(id: id)
        thread.apply(.threadStatusChanged(.init(threadId: id, seq: 1, status: .idle, backgroundTasks: 1)))
        thread.apply(.threadClosed(.init(threadId: id, seq: 2)))
        #expect(!thread.hasBackgroundWork)
    }
}
