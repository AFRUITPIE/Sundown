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
        app.appearance.toolCalls = .everyCall
        app.appearance.offerBypass = true
        app.appearance.sendShortcut = .commandReturn
        app.appearance.openFilesWith = .zed
        app.appearance.sidebar = .activity

        let restored = AppModel(defaults: defaults).appearance

        #expect(restored.toolCalls == .everyCall)
        #expect(restored.sidebar == .activity)
        #expect(restored.offerBypass)
        #expect(restored.sendShortcut == .commandReturn)
        #expect(restored.openFilesWith == .zed)
        #expect(restored.wrapCode)
    }

    /// A store from a build with other settings keeps what it shares and defaults the rest; an
    /// unknown value (a later build's) falls back rather than losing every other choice, and a key
    /// this build dropped is ignored.
    @Test func anOlderOrNewerStoreStillDecodes() throws {
        let json = #"{"density":"spacious","sessionControls":"split","toolCalls":"somethingNew","sendShortcut":"commandReturn","offerBypass":true,"openFilesWith":"emacs"}"#
        let appearance = try JSONDecoder().decode(Appearance.self, from: Data(json.utf8))

        #expect(appearance.toolCalls == .summarized)
        #expect(appearance.openFilesWith == .defaultApp)
        #expect(appearance.sendShortcut == .commandReturn)
        #expect(appearance.offerBypass)
        #expect(appearance.wrapCode)
        #expect(appearance.sidebar == .chats)
    }

    @Test func theSidebarLayoutIsKept() throws {
        var appearance = Appearance()
        appearance.sidebar = .activity
        let decoded = try JSONDecoder().decode(Appearance.self, from: JSONEncoder().encode(appearance))
        #expect(decoded.sidebar == .activity)
    }

    /// Restore Defaults in Advanced leaves General's choices alone.
    @Test func restoringAdvancedKeepsGeneral() {
        var appearance = Appearance()
        appearance.toolCalls = .everyCall
        appearance.sidebar = .activity
        appearance.worktreeByDefault = true
        #expect(!appearance.advancedIsDefault)
        appearance.restoreAdvanced()
        #expect(appearance.advancedIsDefault)
        #expect(appearance.toolCalls == .summarized)
        #expect(appearance.sidebar == .chats)
        #expect(appearance.worktreeByDefault)
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

    /// A host's environment values are kept apart from the defaults file's hosts, and come back
    /// when the host connects.
    @Test func environmentValuesAreKeptApartAndRestored() async throws {
        let store = defaults()
        let app = AppModel(defaults: store)
        var host = HostConfig(name: "build-box", kind: .ssh(destination: "build-box"))
        host.env = ["ANTHROPIC_API_KEY": "sk-test"]
        app.addHost(host)

        let raw = try #require(store.data(forKey: "tether.hosts.v1"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("sk-test"))
        let restored = AppModel(defaults: store)
        #expect(await restored.loadEnvironment(for: host.id) == ["ANTHROPIC_API_KEY": "sk-test"])
        #expect(restored.hosts.first { $0.id == host.id }?.env == ["ANTHROPIC_API_KEY": "sk-test"])
    }

    /// A store from before keeps its values inline; the next save moves them out.
    @Test func inlineValuesMoveOnTheNextSave() async throws {
        let store = defaults()
        let id = UUID()
        let old = #"{"hosts":[{"id":"\#(id.uuidString)","name":"box","kind":{"ssh":{"destination":"box"}},"env":{"AWS_PROFILE":"dev"}}]}"#
        store.set(Data(old.utf8), forKey: "tether.hosts.v1")
        let app = AppModel(defaults: store)
        #expect(app.hosts.first { $0.id == id }?.env == ["AWS_PROFILE": "dev"])

        app.transcriptWidth = .wide
        let raw = try #require(store.data(forKey: "tether.hosts.v1"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("AWS_PROFILE"))
        #expect(await AppModel(defaults: store).loadEnvironment(for: id) == ["AWS_PROFILE": "dev"])
    }

    /// A Keychain that refuses the values leaves them in the defaults file rather than nowhere; the
    /// first save the Keychain takes them on moves them out.
    @Test func valuesStayInlineUntilTheKeychainTakesThem() async throws {
        let store = defaults()
        let id = UUID()
        let old = #"{"hosts":[{"id":"\#(id.uuidString)","name":"box","kind":{"ssh":{"destination":"box"}},"env":{"AWS_PROFILE":"dev"}}]}"#
        store.set(Data(old.utf8), forKey: "tether.hosts.v1")
        let keychain = RefusingSecrets()
        let app = AppModel(defaults: store, secrets: keychain)

        app.transcriptWidth = .wide
        var raw = try #require(store.data(forKey: "tether.hosts.v1"))
        #expect(String(decoding: raw, as: UTF8.self).contains("AWS_PROFILE"))
        #expect(AppModel(defaults: store, secrets: keychain).hosts.first { $0.id == id }?.env == ["AWS_PROFILE": "dev"])

        keychain.refuses = false
        app.transcriptWidth = .medium
        raw = try #require(store.data(forKey: "tether.hosts.v1"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("AWS_PROFILE"))
        #expect(await AppModel(defaults: store, secrets: keychain).loadEnvironment(for: id) == ["AWS_PROFILE": "dev"])
    }
}

/// A secret store that refuses writes until told not to. Used from one test at a time.
private final class RefusingSecrets: SecretStore, @unchecked Sendable {
    var refuses = true
    private var values: [String: Data] = [:]

    func read(_ account: String) -> Data? { values[account] }

    func write(_ data: Data?, for account: String) -> Bool {
        guard !refuses else { return false }
        values[account] = data
        return true
    }
}

@Suite
struct ScheduledTaskTextTests {
    /// Written in the reader's language: "42s", "3h 5m", "12.3K", "$0.42", "$0.0042".
    @Test func numbersAreFormattedForTheLocale() {
        let separator = Locale.current.decimalSeparator ?? "."
        func places(_ s: String) -> Int { s.components(separatedBy: separator).last?.filter(\.isNumber).count ?? 0 }
        #expect(Format.duration(3 * 3600 + 5 * 60 + 9).split(separator: " ").count == 2)
        #expect(Format.tokens(950) == 950.formatted())
        #expect(Format.tokens(12_300) != 12_300.formatted())
        #expect(places(Format.cost(1.5)) == 2)
        #expect(places(Format.cost(0.0042)) == 4)
    }

    private func task(_ cadence: ScheduleCadence, enabled: Bool = true, weekday: Int? = nil) -> ScheduledTask {
        ScheduledTask(id: "t", name: "T", prompt: "p", cwd: "/", cadence: cadence, hour: 9, minute: 5, weekday: weekday, enabled: enabled)
    }

    @Test func aScheduleReadsAsASentence() {
        let nine = ScheduledTaskText.time(hour: 9, minute: 5)
        #expect(ScheduledTaskText.summary(task(.manual)) == "Only When Run")
        #expect(ScheduledTaskText.summary(task(.hourly)) == "Every hour at :05")
        #expect(ScheduledTaskText.summary(task(.weekdays)) == "Weekdays at \(nine)")
        let friday = Calendar.current.weekdaySymbols[5]
        #expect(ScheduledTaskText.summary(task(.weekly, weekday: 6)) == "Every \(friday) at \(nine)")
        #expect(ScheduledTaskText.summary(task(.daily, enabled: false)) == "Off · Every day at \(nine)")
    }
}
