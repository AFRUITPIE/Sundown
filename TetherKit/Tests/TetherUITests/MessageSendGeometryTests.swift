import SwiftUI
import Testing
@testable import TetherUI

@MainActor @Suite struct MessageSendGeometryTests {
    @Test func staleCompletionCannotEndANewerFlight() {
        let geometry = MessageSendGeometry()
        geometry.activeMessageID = "second"
        geometry.finishSend("first")
        #expect(geometry.activeMessageID == "second")
        geometry.finishSend("second")
        #expect(geometry.activeMessageID == nil)
    }

    @Test func clearingTheComposerDoesNotChangeTheSubmittedShape() {
        let geometry = MessageSendGeometry()
        let filled = CGRect(x: 20, y: 400, width: 500, height: 150)
        geometry.composerFrame = filled
        geometry.prepareSend()
        geometry.composerFrame = CGRect(x: 20, y: 510, width: 500, height: 40)
        #expect(geometry.submittedFrame == filled)
    }
}
