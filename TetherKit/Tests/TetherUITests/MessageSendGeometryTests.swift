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

    /// A prompt is in place once its row has taken the launch, flying or not (Reduce Motion takes
    /// it without flying), and its flight is over; a message sent after it doesn't hold it up.
    @Test func aPromptHasLandedOnceTakenAndFlown() async {
        let geometry = MessageSendGeometry()
        geometry.composerFrame = CGRect(x: 20, y: 400, width: 500, height: 40)
        geometry.prepareSend()
        #expect(geometry.hasLaunch)
        let landed = Task { await geometry.landed("first"); return true }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(geometry.takeLaunch(for: "first") != nil)
        #expect(!geometry.hasLaunch)
        let began = ContinuousClock.now
        geometry.beginFlight("first")
        // The next message, waiting for its own row.
        geometry.prepareSend()
        #expect(await landed.value)
        // Where it lands, not when the spring's tail ends.
        #expect(ContinuousClock.now - began >= MessageSendGeometry.flightLands)
        #expect(geometry.activeMessageID == "first")
        #expect(geometry.hasLaunch)
        #expect(geometry.takeLaunch(for: "second") != nil)
        #expect(geometry.takeLaunch(for: "second") == nil)
    }

    @Test func nothingSentHasLandedAlready() async {
        let geometry = MessageSendGeometry()
        await geometry.landed("anything")
        #expect(!geometry.hasLaunch)
    }
}
