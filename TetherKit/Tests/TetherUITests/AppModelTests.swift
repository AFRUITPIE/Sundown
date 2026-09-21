import Foundation
import Testing
import TetherKit
@testable import TetherUI

@MainActor
@Suite
struct AppModelTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)")!
    }

    @Test func opensOnANewLocalChat() {
        let app = AppModel(defaults: isolatedDefaults())

        #expect(app.selection == .newChat(host: HostConfig.local.id))
        #expect(app.selectedThread == nil)
    }

    @Test func newChatKeepsTheSelectedHost() {
        let app = AppModel(defaults: isolatedDefaults())
        app.selection = .thread(host: HostConfig.local.id, id: "thread-1")

        app.newChat()

        #expect(app.selection == .newChat(host: HostConfig.local.id))
        #expect(app.selectedThread == nil)
    }

    @Test func defaultsRoundTripWithoutUsingStandardDefaults() {
        let defaults = isolatedDefaults()
        let app = AppModel(defaults: defaults)
        app.defaultModel = "sonnet"
        app.defaultEffort = "high"
        app.defaultPermissionMode = "plan"
        app.transcriptWidth = .wide

        let restored = AppModel(defaults: defaults)

        #expect(restored.defaultModel == "sonnet")
        #expect(restored.defaultEffort == "high")
        #expect(restored.defaultPermissionMode == "plan")
        #expect(restored.transcriptWidth == .wide)
    }

    @Test func newChatUsesTheConfiguredDefaults() {
        let app = AppModel(defaults: isolatedDefaults())
        app.defaultModel = "sonnet"
        app.defaultEffort = "high"
        app.defaultPermissionMode = "plan"

        app.newChat()

        #expect(app.draftModel == "sonnet")
        #expect(app.draftEffort == .high)
        #expect(app.draftPermissionMode == .plan)
    }
}

@Suite
struct SettingsDestinationTests {
    @Test func stableDestinationsRoundTrip() {
        #expect(SettingsDestination(storedValue: SettingsDestination.general.storedValue) == .general)
        #expect(SettingsDestination(storedValue: SettingsDestination.chats.storedValue) == .chats)
        #expect(SettingsDestination(storedValue: SettingsDestination.hosts.storedValue) == .hosts)
    }

    @Test func unknownOrMalformedDestinationFallsBackToGeneral() {
        #expect(SettingsDestination(storedValue: "unknown") == .general)
    }

    @Test func sidebarDestinationsMigrateToTheirToolbarPane() {
        #expect(SettingsDestination(storedValue: "newChats") == .chats)
        #expect(SettingsDestination(storedValue: "host:\(UUID().uuidString)") == .hosts)
    }
}
