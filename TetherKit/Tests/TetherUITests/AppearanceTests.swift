import Foundation
import Testing
@testable import TetherUI

@MainActor
@Suite
struct AppearanceTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)")!
    }

    @Test func choicesAreKeptAcrossLaunches() {
        let defaults = isolatedDefaults()
        let app = AppModel(defaults: defaults)
        app.appearance.density = .compact
        app.appearance.toolIcons = true
        app.appearance.sendShortcut = .commandReturn

        let restored = AppModel(defaults: defaults).appearance

        #expect(restored.density == .compact)
        #expect(restored.toolIcons)
        #expect(restored.sendShortcut == .commandReturn)
        #expect(restored.replyFont == .system)
    }

    /// A store from a build that had fewer settings keeps what it had and defaults the rest; an
    /// unknown value (a later build's) falls back rather than losing every other choice.
    @Test func aPartialOrNewerStoreStillDecodes() throws {
        let json = #"{"density":"spacious","composerLayout":"somethingNew","groupToolCalls":false}"#
        let appearance = try JSONDecoder().decode(Appearance.self, from: Data(json.utf8))

        #expect(appearance.density == .spacious)
        #expect(!appearance.groupToolCalls)
        #expect(appearance.composerLayout == .messages)
        #expect(appearance.fadeInText)
    }

    @Test func textSizeStepsReadAsPercentages() {
        #expect(TextScale.label(1) == "100%")
        #expect(TextScale.label(0.85) == "85%")
        #expect(TextScale.label(1.75) == "175%")
    }
}
