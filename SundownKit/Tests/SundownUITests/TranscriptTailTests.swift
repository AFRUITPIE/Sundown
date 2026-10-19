@testable import SundownFixtures
import Testing
import TetherProtocol
@testable import SundownKit
@testable import SundownUI

/// The line that ends a turn that stopped short.
@MainActor
@Suite
struct TranscriptTailTests {
    private func failedTurn(errors: [String]?) -> Turn {
        .sample(status: .failed, secondsAgo: 30,
                result: .sample(subtype: "error_during_execution", isError: true, errors: errors))
    }

    /// A failed turn says why in words, or that it failed, never the result's raw subtype such as
    /// `error_during_execution` (#50).
    @Test func aFailedTurnSaysSoInWords() {
        let silent = TurnOutcome(turn: failedTurn(errors: nil)).words
        #expect(silent == "The turn failed", "A failure without a reason doesn't say it failed: \(silent)")
        let explained = TurnOutcome(turn: failedTurn(errors: ["SSH connection to deploy-01 timed out"])).words
        #expect(explained == "SSH connection to deploy-01 timed out", "The reason isn't shown: \(explained)")
    }

    /// A stopped turn says so.
    @Test func anInterruptedTurnSaysSo() {
        #expect(TurnOutcome(turn: .sample(status: .interrupted, secondsAgo: 30)).words == "Interrupted")
    }
}
