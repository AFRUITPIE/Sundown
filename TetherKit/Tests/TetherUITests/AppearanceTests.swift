import Foundation
import Testing
import TetherKit
import TetherProtocol
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

@MainActor
@Suite
struct SidebarFilterTests {
    @Test func archivedChatsAreOnlyInArchived() {
        let archived = ThreadModel.sampleListed(title: "Old", cwd: "/tmp", secondsAgo: 10, tag: ThreadModel.archivedTag)
        let current = ThreadModel.sampleListed(title: "New", cwd: "/tmp", secondsAgo: 5)
        #expect(!SidebarFilter.all.includes(archived))
        #expect(SidebarFilter.all.includes(current))
        #expect(SidebarFilter.archived.includes(archived))
        #expect(!SidebarFilter.archived.includes(current))
    }

    @Test func workingAndWaiting() {
        let running = ThreadModel.sampleRunningTurn()
        let waiting = ThreadModel.samplePendingPermission()
        let idle = ThreadModel.sampleIdleChat()
        #expect(SidebarFilter.working.includes(running))
        #expect(!SidebarFilter.working.includes(idle))
        #expect(SidebarFilter.waiting.includes(waiting))
        #expect(!SidebarFilter.waiting.includes(idle))
    }
}

@MainActor
@Suite
struct HostSecretsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)")! }

    /// A host's environment values are kept apart from the defaults file's hosts, and come back.
    @Test func environmentValuesAreKeptApartAndRestored() throws {
        let store = defaults()
        let app = AppModel(defaults: store)
        var host = HostConfig(name: "build-box", kind: .ssh(destination: "build-box"))
        host.env = ["ANTHROPIC_API_KEY": "sk-test"]
        app.addHost(host)

        let raw = try #require(store.data(forKey: "tether.hosts.v1"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("sk-test"))
        let restored = AppModel(defaults: store)
        #expect(restored.hosts.first { $0.id == host.id }?.env == ["ANTHROPIC_API_KEY": "sk-test"])
    }

    /// A store from before keeps its values inline; the next save moves them out.
    @Test func inlineValuesMoveOnTheNextSave() throws {
        let store = defaults()
        let id = UUID()
        let old = #"{"hosts":[{"id":"\#(id.uuidString)","name":"box","kind":{"ssh":{"destination":"box"}},"env":{"AWS_PROFILE":"dev"}}]}"#
        store.set(Data(old.utf8), forKey: "tether.hosts.v1")
        let app = AppModel(defaults: store)
        #expect(app.hosts.first { $0.id == id }?.env == ["AWS_PROFILE": "dev"])

        app.transcriptWidth = .wide
        let raw = try #require(store.data(forKey: "tether.hosts.v1"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("AWS_PROFILE"))
        #expect(AppModel(defaults: store).hosts.first { $0.id == id }?.env == ["AWS_PROFILE": "dev"])
    }
}

@Suite
struct ToolCallVisibilityTests {
    private func call(_ id: String, _ status: ToolStatus, kind: ToolKind = .bash) -> TranscriptRow {
        .item(.toolCall(.sample(id: id, name: "Bash", kind: kind, input: [:], status: status, secondsAgo: 1)))
    }

    @Test func quietCallsAreFinishedOnes() {
        #expect(call("a", .completed).isQuietToolCall)
        #expect(!call("b", .running).isQuietToolCall)
        #expect(!call("c", .failed).isQuietToolCall)
        #expect(!call("d", .completed, kind: .todoWrite).isQuietToolCall)
        #expect(TranscriptRow.toolGroup([]).isQuietToolCall)
    }

    @Test func messagesAreNeverToolCalls() {
        let message = TranscriptRow.item(.agentMessage(.init(id: "m", createdAt: 0, text: "hi")))
        #expect(!message.isToolCall && !message.isQuietToolCall)
        #expect(call("a", .running).isToolCall)
    }
}
