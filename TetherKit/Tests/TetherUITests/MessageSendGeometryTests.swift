import SwiftUI
import Testing
@testable import TetherUI

@MainActor @Suite struct MessageSendGeometryTests {
    @Test func finishingAnEarlierFlightPreservesTheNextPreparation() {
        let geometry = MessageSendGeometry()
        let first = geometry.prepareSend()
        geometry.activeMessageID = "first"
        let second = geometry.prepareSend()
        geometry.finishSend("first", preparation: first)
        #expect(geometry.preparationID == second)
        geometry.cancelPreparation(second)
        #expect(geometry.preparationID == nil)
    }

    @Test func staleCompletionCannotEndANewerFlight() {
        let geometry = MessageSendGeometry()
        let first = geometry.prepareSend()
        geometry.activeMessageID = "first"
        let second = geometry.prepareSend()
        geometry.activeMessageID = "second"
        geometry.departingMessageID = "second"
        geometry.finishSend("first", preparation: first)
        #expect(geometry.activeMessageID == "second")
        #expect(geometry.departingMessageID == "second")
        #expect(geometry.preparationID == second)
        geometry.finishSend("second", preparation: second)
        #expect(geometry.activeMessageID == nil)
        #expect(geometry.departingMessageID == nil)
        #expect(geometry.preparationID == nil)
    }

    @Test func clearingTheComposerDoesNotChangeTheSubmittedShape() {
        let geometry = MessageSendGeometry()
        let filled = CGRect(x: 20, y: 400, width: 500, height: 150)
        geometry.composerFrame = filled
        _ = geometry.prepareSend()
        geometry.composerFrame = CGRect(x: 20, y: 510, width: 500, height: 40)
        #expect(geometry.submittedFrame == filled)
    }
}
