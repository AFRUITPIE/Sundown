import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

@MainActor
@Suite
struct SendAnimationTests {
    private let input: [UserInput] = [.text(.init(text: "Check the layout"))]

    private func message(_ id: String, content: [UserInput]? = nil,
                         synthetic: Bool? = nil, origin: String? = nil,
                         parent: String? = nil) -> Item {
        .userMessage(.init(id: id, parentToolUseId: parent, createdAt: 0,
                          content: content ?? input, synthetic: synthetic, origin: origin))
    }

    private func echo(_ item: Item, seq: Int) -> ServerNotification {
        .itemStarted(.init(threadId: "chat", seq: seq, item: item))
    }

    @Test func onlyTheReturnedMessageInTheSendingWindowAnimatesOnce() {
        let thread = ThreadModel(id: "chat")
        let owner = UUID(), otherWindow = UUID()
        thread.apply(echo(message("history"), seq: 1))
        let token = thread.beginLocalSend(owner: owner)
        thread.apply(echo(message("other-client"), seq: 2))
        thread.apply(echo(message("local"), seq: 3))
        // Even identical content cannot select a message before the actual RPC result arrives.
        #expect(!thread.canAnimateSend("local", owner: owner))
        thread.confirmLocalSend(messageID: "local", token: token)
        #expect(!thread.canAnimateSend("history", owner: owner))
        #expect(!thread.canAnimateSend("other-client", owner: owner))
        #expect(!thread.canAnimateSend("local", owner: otherWindow))
        #expect(!thread.consumeSendAnimation("local", owner: otherWindow))
        #expect(thread.consumeSendAnimation("local", owner: owner))
        // Streaming can rebuild the row during the handoff. Its task key stays true while the
        // once-only claim prevents another row instance from replaying it.
        #expect(thread.isRecentLocalSend("local", owner: owner))
        #expect(!thread.canAnimateSend("local", owner: owner))
        #expect(!thread.consumeSendAnimation("local", owner: owner))
        thread.apply(echo(message("local"), seq: 4))
        #expect(thread.isRecentLocalSend("local", owner: owner))
        #expect(!thread.canAnimateSend("local", owner: owner))
    }

    @Test func aNewerSendSupersedesThePreviousResponseAndHandoff() {
        let thread = ThreadModel(id: "chat")
        let owner = UUID()
        let first = thread.beginLocalSend(owner: owner)
        let second = thread.beginLocalSend(owner: owner)
        thread.confirmLocalSend(messageID: "first", token: first)
        #expect(!thread.canAnimateSend("first", owner: owner))
        thread.confirmLocalSend(messageID: "second", token: second)
        #expect(thread.canAnimateSend("second", owner: owner))
        let third = thread.beginLocalSend(owner: owner)
        #expect(!thread.canAnimateSend("second", owner: owner))
        thread.confirmLocalSend(messageID: "third", token: third)
        #expect(thread.consumeSendAnimation("third", owner: owner))
    }

    @Test func aFailedSendAndSendWithoutAWindowCannotAnimate() {
        let thread = ThreadModel(id: "chat")
        let owner = UUID()
        let token = thread.beginLocalSend(owner: owner)
        thread.cancelLocalSend(token: token)
        thread.confirmLocalSend(messageID: "late", token: token)
        #expect(!thread.canAnimateSend("late", owner: owner))
        let ownerless = thread.beginLocalSend(owner: nil)
        thread.confirmLocalSend(messageID: "ownerless", token: ownerless)
        #expect(!thread.canAnimateSend("ownerless", owner: owner))
    }

    @Test func aNewChatFindsItsInitialPromptAlreadyReceived() {
        let thread = ThreadModel(id: "new-chat")
        let owner = UUID()
        thread.loadHistory(items: [message("initial")], turns: [], seq: nil)
        thread.prepareInitialSend(input, owner: owner)
        #expect(thread.consumeSendAnimation("initial", owner: owner))
        #expect(!thread.consumeSendAnimation("initial", owner: owner))
    }

    @Test func aNewChatWaitsForItsFirstHumanPromptOnly() {
        let thread = ThreadModel(id: "new-chat")
        let owner = UUID()
        thread.prepareInitialSend(input, owner: owner)
        thread.apply(echo(message("peer", origin: "peer"), seq: 1))
        thread.apply(echo(message("synthetic", synthetic: true), seq: 2))
        thread.apply(echo(message("child", parent: "agent"), seq: 3))
        #expect(!thread.canAnimateSend("peer", owner: owner))
        #expect(!thread.canAnimateSend("synthetic", owner: owner))
        #expect(!thread.canAnimateSend("child", owner: owner))
        thread.apply(echo(message("initial"), seq: 4))
        #expect(thread.consumeSendAnimation("initial", owner: owner))
        thread.apply(echo(message("later"), seq: 5))
        #expect(!thread.canAnimateSend("later", owner: owner))
    }

    @Test func aDifferentFirstPromptCannotMatchALaterPrompt() {
        let thread = ThreadModel(id: "new-chat")
        let owner = UUID()
        thread.prepareInitialSend(input, owner: owner)
        thread.apply(echo(message("different", content: [.text(.init(text: "A different initial prompt"))]), seq: 1))
        thread.apply(echo(message("later-matching"), seq: 2))
        #expect(!thread.canAnimateSend("different", owner: owner))
        #expect(!thread.canAnimateSend("later-matching", owner: owner))
    }
}
