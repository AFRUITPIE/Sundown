import AppKit
import Foundation
@testable import SundownFixtures
import Synchronization
import Testing
import SundownKit
@testable import SundownUI

@MainActor
@Suite
struct PreferenceWriteTests {
    /// Choosing a chat or a pane writes where the last window was, under its own small key; the
    /// hosts, pins and preferences aren't written again each time.
    @Test func aChatSwitchWritesOnlyTheLastWindow() throws {
        let defaults = try #require(CountingDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
        let app = AppModel.sample(connections: [.sample()], defaults: defaults)
        let w = WindowModel(app: app, target: app.newWindowTarget())
        w.start()
        let chats = try #require(w.connection?.chats)
        defaults.keys.removeAll()

        w.open(threadID: chats[0].id)
        w.open(threadID: chats[1].id)
        w.tab = .diff

        #expect(!defaults.keys.contains("sundown.hosts.v1"))
        #expect(defaults.keys.allSatisfy { $0 == "sundown.window.v1" })
        #expect(!defaults.keys.isEmpty)

        // The same again: nothing written.
        defaults.keys.removeAll()
        app.remember(w)
        app.transcriptWidth = app.transcriptWidth
        #expect(defaults.keys.isEmpty)
    }
}

@MainActor
@Suite
struct DraftWriteTests {
    private func appModel(draftsAt url: URL) throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
        return AppModel(defaults: defaults, secrets: DefaultsSecrets(defaults), draftsURL: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// A save with nothing new writes nothing, and typing that comes back to what was written
    /// isn't written again.
    @Test func draftsAreWrittenOnlyWhenTheyChanged() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let app = try appModel(draftsAt: file)

        // Quitting with nothing typed.
        app.saveDrafts()
        #expect(!exists(file))

        app.setDraft("half a thought", for: "a")
        app.saveDrafts()
        #expect(exists(file))

        // Gone, so a write would bring it back.
        try FileManager.default.removeItem(at: file)
        app.saveDrafts()
        #expect(!exists(file))

        app.setDraft("half a thought, then more", for: "a")
        app.setDraft("half a thought", for: "a")
        app.saveDrafts()
        #expect(!exists(file))
    }

    /// Written in the background, in order, and at quit before the app goes.
    @Test func draftsAreWrittenInTheBackgroundAndAtQuit() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let app = try appModel(draftsAt: file)
        app.setDraft("one", for: "a")
        app.setDraft("two", for: "b")

        app.forgetDraft(for: "a")
        app.waitForDraftWrites()
        let written = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        #expect(written == ["b": "two"])

        app.setDraft("three", for: "c")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) == ["b": "two", "c": "three"])
    }
}

@MainActor
@Suite
struct KeychainReadTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
    }

    /// Launching asks the Keychain for the hosts that have values, once and only for them.
    @Test func onlyHostsWithValuesAreReadAndOnlyOnce() async throws {
        let store = try defaults()
        let secrets = CountingSecrets()
        let first = AppModel(defaults: store, secrets: secrets)
        var withValues = HostConfig(name: "with", kind: .ssh(destination: "with"))
        withValues.env = ["AWS_PROFILE": "dev"]
        let without = HostConfig(name: "without", kind: .ssh(destination: "without"))
        first.addHost(withValues)
        first.addHost(without)
        secrets.reads.withLock { $0 = [] }

        let app = AppModel(defaults: store, secrets: secrets)
        #expect(secrets.reads.withLock { $0 }.isEmpty)
        #expect(app.hosts.first { $0.id == withValues.id }?.env == [:])

        await app.environmentLoaded()
        await app.environmentLoaded()
        #expect(app.hosts.first { $0.id == withValues.id }?.env == ["AWS_PROFILE": "dev"])
        #expect(app.connection(withValues.id)?.host.env == ["AWS_PROFILE": "dev"])
        #expect(app.hosts.first { $0.id == without.id }?.env == [:])
        #expect(secrets.reads.withLock { $0 } == [withValues.id.uuidString])
    }

    /// Changed in Settings before the values were read: what was typed stays.
    @Test func aChangeBeforeTheValuesAreReadKeepsWhatWasTyped() async throws {
        let store = try defaults()
        let secrets = CountingSecrets()
        var host = HostConfig(name: "box", kind: .ssh(destination: "box"))
        host.env = ["AWS_PROFILE": "dev"]
        AppModel(defaults: store, secrets: secrets).addHost(host)

        let app = AppModel(defaults: store, secrets: secrets)
        var renamed = try #require(app.hosts.first { $0.id == host.id })
        renamed.env = ["AWS_REGION": "us-west-2"]
        app.updateHost(renamed)
        await app.environmentLoaded()

        #expect(app.hosts.first { $0.id == host.id }?.env == ["AWS_REGION": "us-west-2"])
    }
}

@MainActor
@Suite
struct ConnectOrderTests {
    /// The hosts windows show connect first; the rest once those are up, or as soon as a window
    /// shows one.
    @Test func shownHostsConnectFirst() async throws {
        let ssh = HostConfig(name: "Fixture SSH", kind: .ssh(destination: "fixture.invalid"))
        let local = UITestFixture.connection(), remote = UITestFixture.connection(host: ssh)
        let app = AppModel.sample(connections: [local, remote])
        let w = WindowModel(app: app, target: WindowTarget(hostID: local.id))
        w.start()

        app.connectAll()
        #expect(app.waitingHosts == [remote.id])
        try await eventually { local.state == .connected && remote.state == .connected }
        #expect(app.waitingHosts.isEmpty)
    }

    @Test func aWindowShowingAWaitingHostConnectsIt() async throws {
        let ssh = HostConfig(name: "Fixture SSH", kind: .ssh(destination: "fixture.invalid"))
        let local = UITestFixture.connection(), remote = UITestFixture.connection(host: ssh)
        let app = AppModel.sample(connections: [local, remote])
        let w = WindowModel(app: app, target: WindowTarget(hostID: local.id))
        w.start()
        app.connectAll()

        w.hostID = remote.id
        #expect(app.waitingHosts.isEmpty)
        try await eventually { remote.state == .connected }
    }
}

/// Records which keys are written.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var keys: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        keys.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}

/// Secrets in memory, counting reads.
private final class CountingSecrets: SecretStore, @unchecked Sendable {
    let reads = Mutex<[String]>([])
    private let values = Mutex<[String: Data]>([:])

    func read(_ account: String) -> Data? {
        reads.withLock { $0.append(account) }
        return values.withLock { $0[account] }
    }

    @discardableResult func write(_ data: Data?, for account: String) -> Bool {
        values.withLock { $0[account] = data }
        return true
    }
}
