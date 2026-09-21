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

        #expect(app.hostID == HostConfig.local.id)
        #expect(app.threadID == nil)
        #expect(app.selectedThread == nil)
    }

    @Test func selectingAChatResolvesItOnTheCurrentHost() {
        let app = AppModel(defaults: isolatedDefaults())

        app.open(threadID: "thread-1")

        #expect(app.threadID == "thread-1")
        #expect(app.selectedThread?.id == "thread-1")
        // The same identity every time, or subscriptions and pending prompts would be lost.
        let again = app.selectedThread
        app.threadID = "thread-1"
        #expect(app.selectedThread === again)
    }

    @Test func newChatKeepsTheSelectedHost() {
        let app = AppModel(defaults: isolatedDefaults())
        app.open(threadID: "thread-1")

        app.newChat()

        #expect(app.hostID == HostConfig.local.id)
        #expect(app.threadID == nil)
        #expect(app.selectedThread == nil)
    }

    @Test func switchingHostClearsTheSelectedChat() {
        let app = AppModel.sample(connections: [.sample(), .sampleFailed()])
        let other = app.hosts[1].id
        app.open(threadID: "thread-1")

        app.hostID = other

        #expect(app.threadID == nil)
        #expect(app.selectedThread == nil)
    }

    @Test func removingTheCurrentHostFallsBackToLocal() {
        let app = AppModel.sample(connections: [.sample(), .sampleFailed()])
        let other = app.hosts[1].id
        app.hostID = other
        app.open(threadID: "thread-1")

        app.removeHost(other)

        #expect(app.hostID == HostConfig.local.id)
        #expect(app.threadID == nil)
        #expect(app.connection?.host.id == HostConfig.local.id)
    }

    @Test func aStoredHostThatIsGoneFallsBackToLocal() {
        let app = AppModel(defaults: isolatedDefaults())

        app.hostID = UUID()

        #expect(app.hostID == HostConfig.local.id)
    }

    @Test func defaultsRoundTripWithoutUsingStandardDefaults() {
        let defaults = isolatedDefaults()
        // Sample connections: a second host without connecting to anything.
        let app = AppModel.sample(connections: [.sample(), .sampleFailed()], defaults: defaults)
        let other = app.hosts[1].id
        app.defaultModel = "sonnet"
        app.defaultEffort = "high"
        app.defaultPermissionMode = "plan"
        app.transcriptWidth = .wide
        app.showInspector = true
        app.sidebarGrouping = .directory
        app.hostID = other

        let restored = AppModel(defaults: defaults)

        #expect(restored.defaultModel == "sonnet")
        #expect(restored.defaultEffort == "high")
        #expect(restored.defaultPermissionMode == "plan")
        #expect(restored.transcriptWidth == .wide)
        #expect(restored.showInspector)
        #expect(restored.sidebarGrouping == .directory)
        #expect(restored.hostID == other)
    }

    @Test func aStoreWrittenBeforeTheseKeysExistedStillDecodes() {
        let defaults = isolatedDefaults()
        let old = """
        {"hosts":[],"defaultModel":"opus","transcriptWidth":"medium"}
        """
        defaults.set(Data(old.utf8), forKey: "tether.hosts.v1")

        let app = AppModel(defaults: defaults)

        #expect(app.defaultModel == "opus")
        #expect(app.transcriptWidth == .medium)
        #expect(!app.showInspector)
        #expect(app.sidebarGrouping == .date)
        #expect(app.hostID == HostConfig.local.id)
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
        #expect(SettingsDestination(storedValue: SettingsDestination.hosts.storedValue) == .hosts)
    }

    @Test func unknownOrMalformedDestinationFallsBackToGeneral() {
        #expect(SettingsDestination(storedValue: "unknown") == .general)
    }

    /// Panes earlier builds had: the new-chat defaults moved into General, and a per-host
    /// destination is now a selection inside Hosts.
    @Test func retiredDestinationsMigrateToThePaneThatAbsorbedThem() {
        #expect(SettingsDestination(storedValue: "chats") == .general)
        #expect(SettingsDestination(storedValue: "newChats") == .general)
        #expect(SettingsDestination(storedValue: "hosts") == .hosts)
        #expect(SettingsDestination(storedValue: "host:\(UUID().uuidString)") == .hosts)
    }
}
