import SwiftUI
import Testing
import TetherProtocol
@testable import SundownKit
@testable import SundownUI

/// The line that ends a turn that stopped short. A test can't read what SwiftUI draws (a hosted
/// view builds no accessibility tree without a client), so these read the strings the view's body
/// holds, through the app's own views it's made of.
@MainActor
@Suite
struct TranscriptTailTests {
    /// Every string in a view's body, and in the bodies of the app's views inside it. SwiftUI's own
    /// views are read only as values: their `body` must never be called.
    private func strings(in view: any View, depth: Int = 0) -> [String] {
        func walk(_ value: Any, _ level: Int) -> [String] {
            guard level < 40 else { return [] }
            if let string = value as? String { return [string] }
            if let view = value as? any View, String(reflecting: type(of: view)).hasPrefix("SundownUI.") {
                return strings(in: view, depth: depth + 1)
            }
            return Mirror(reflecting: value).children.flatMap { walk($0.value, level + 1) }
        }
        guard depth < 8 else { return [] }
        return walk(view.body, 0)
    }

    private func failedTurn(errors: [String]?) -> ThreadModel {
        .sample(status: .idle, items: [.sampleUserMessage("Deploy it.", secondsAgo: 60)], turns: [
            .sample(status: .failed, secondsAgo: 30,
                    result: .sample(subtype: "error_during_execution", isError: true, errors: errors)),
        ])
    }

    /// A failed turn says why in words, or that it failed, never the result's raw subtype such as
    /// `error_during_execution` (#50).
    @Test func aFailedTurnSaysSoInWords() {
        let silent = strings(in: TranscriptTail(thread: failedTurn(errors: nil)))
        #expect(silent.contains("The turn failed"), "A failure without a reason doesn't say it failed: \(silent)")
        #expect(!silent.contains { $0.contains("error_during_execution") }, "The raw subtype is shown: \(silent)")

        let explained = strings(in: TranscriptTail(thread: failedTurn(errors: ["SSH connection to deploy-01 timed out"])))
        #expect(explained.contains("SSH connection to deploy-01 timed out"), "The reason isn't shown: \(explained)")
        #expect(!explained.contains { $0.contains("error_during_execution") }, "The raw subtype is shown: \(explained)")
    }
}
