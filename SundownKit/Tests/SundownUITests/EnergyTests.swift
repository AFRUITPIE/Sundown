import AppKit
import Foundation
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

    /// Where the last window was moves out of an older build's store, once, and still reopens there.
    @Test func theLastWindowMovesToItsOwnKeyOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
        let host = UUID()
        let old = #"{"hosts":[{"id":"\#(host.uuidString)","name":"box","kind":{"ssh":{"destination":"box"}},"env":{}}],"hostID":"\#(host.uuidString)","threadID":"t-7","showInspector":true,"inspectorPane":"changes"}"#
        defaults.set(Data(old.utf8), forKey: "sundown.hosts.v1")

        let app = AppModel(defaults: defaults)
        #expect(app.lastHostID == host && app.lastThreadID == "t-7")
        #expect(defaults.data(forKey: "sundown.window.v1") != nil)

        // The next save of the rest leaves the old fields out; the window is still found.
        app.transcriptWidth = .wide
        let raw = String(decoding: try #require(defaults.data(forKey: "sundown.hosts.v1")), as: UTF8.self)
        #expect(!raw.contains("t-7"))
        let restored = AppModel(defaults: defaults)
        #expect(restored.lastHostID == host && restored.lastThreadID == "t-7")
    }
}

@MainActor
@Suite
struct DraftWriteTests {
    /// A save with nothing new writes nothing, and the same drafts are the same bytes, not written again.
    @Test func draftsAreWrittenOnlyWhenTheyChanged() throws {
        let defaults = try #require(UserDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
        let store = CountingDrafts()
        let app = AppModel(defaults: defaults, secrets: DefaultsSecrets(defaults), draftStore: store)

        // Quitting with nothing typed.
        app.saveDrafts()
        #expect(store.writes == 0)

        app.setDraft("half a thought", for: "a")
        app.saveDrafts()
        #expect(store.writes == 1)
        app.saveDrafts()
        #expect(store.writes == 1)

        app.setDraft("half a thought, then more", for: "a")
        app.setDraft("half a thought", for: "a")
        app.saveDrafts()
        #expect(store.writes == 1)
    }

    /// Written off the main thread, but at quit before the app goes.
    @Test func draftsAreWrittenInTheBackgroundExceptAtQuit() throws {
        let defaults = try #require(UserDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
        let store = CountingDrafts()
        let app = AppModel(defaults: defaults, secrets: DefaultsSecrets(defaults), draftStore: store)
        app.setDraft("one", for: "a")
        app.setDraft("two", for: "b")

        app.forgetDraft(for: "a")
        app.waitForDraftWrites()
        #expect(store.writes == 1)
        #expect(store.onMainThread == [false])
        #expect(store.read() == ["b": "two"])

        app.setDraft("three", for: "c")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(store.writes == 2)
        #expect(store.read()["c"] == "three")
    }
}

@MainActor
@Suite
struct KeychainReadTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "sundown.tests.\(UUID().uuidString)"))
    }

    /// Launching asks the Keychain nothing: a host with values is read when it connects, and a
    /// host without any never is.
    @Test func onlyHostsWithValuesAreReadAndOnlyWhenTheyConnect() async throws {
        let store = try defaults()
        let secrets = CountingSecrets()
        let first = AppModel(defaults: store, secrets: secrets)
        _ = await first.loadEnvironment(for: HostConfig.local.id)
        var withValues = HostConfig(name: "with", kind: .ssh(destination: "with"))
        withValues.env = ["AWS_PROFILE": "dev"]
        let without = HostConfig(name: "without", kind: .ssh(destination: "without"))
        first.addHost(withValues)
        first.addHost(without)
        secrets.reads.withLock { $0 = [] }

        let app = AppModel(defaults: store, secrets: secrets)
        #expect(secrets.reads.withLock { $0 }.isEmpty)
        #expect(app.connection(withValues.id)?.loadEnvironment != nil)
        #expect(app.connection(without.id)?.loadEnvironment == nil)
        #expect(app.connection(HostConfig.local.id)?.loadEnvironment == nil)

        #expect(await app.loadEnvironment(for: withValues.id) == ["AWS_PROFILE": "dev"])
        #expect(await app.loadEnvironment(for: withValues.id) == ["AWS_PROFILE": "dev"])
        #expect(await app.loadEnvironment(for: without.id) == [:])
        #expect(secrets.reads.withLock { $0 } == [withValues.id.uuidString])
    }

    /// An older store doesn't say which hosts have values: each is read once, and then it says.
    @Test func anOlderStoreIsReadOnceThenRecordsWhichHostsHaveValues() async throws {
        let store = try defaults()
        let secrets = CountingSecrets()
        let a = UUID(), b = UUID()
        let old = #"{"hosts":[{"id":"\#(a.uuidString)","name":"a","kind":{"ssh":{"destination":"a"}},"env":{}},{"id":"\#(b.uuidString)","name":"b","kind":{"ssh":{"destination":"b"}},"env":{}}]}"#
        store.set(Data(old.utf8), forKey: "sundown.hosts.v1")
        secrets.write(try JSONEncoder().encode(["TOKEN": "x"]), for: a.uuidString)

        let app = AppModel(defaults: store, secrets: secrets)
        #expect(app.connection(a)?.loadEnvironment != nil)
        #expect(app.connection(b)?.loadEnvironment != nil)
        for id in [HostConfig.local.id, a, b] { _ = await app.loadEnvironment(for: id) }

        let next = AppModel(defaults: store, secrets: secrets)
        #expect(next.connection(a)?.loadEnvironment != nil)
        #expect(next.connection(b)?.loadEnvironment == nil)
        #expect(next.connection(HostConfig.local.id)?.loadEnvironment == nil)
    }

    /// Changed in Settings before its values were read: they're kept, under anything typed.
    @Test func aChangeBeforeTheValuesAreReadKeepsThem() async throws {
        let store = try defaults()
        let secrets = CountingSecrets()
        var host = HostConfig(name: "box", kind: .ssh(destination: "box"))
        host.env = ["AWS_PROFILE": "dev"]
        AppModel(defaults: store, secrets: secrets).addHost(host)

        let app = AppModel(defaults: store, secrets: secrets)
        var renamed = try #require(app.hosts.first { $0.id == host.id })
        renamed.name = "Build Box"
        renamed.env = ["AWS_REGION": "us-west-2"]
        app.updateHost(renamed)

        #expect(app.hosts.first { $0.id == host.id }?.env == ["AWS_PROFILE": "dev", "AWS_REGION": "us-west-2"])
        #expect(await AppModel(defaults: store, secrets: secrets).loadEnvironment(for: host.id)
                == ["AWS_PROFILE": "dev", "AWS_REGION": "us-west-2"])
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

/// Drafts in memory, counting writes and where they happened.
private final class CountingDrafts: DraftStore, @unchecked Sendable {
    private let state = Mutex<(data: Data?, writes: Int, onMain: [Bool])>((nil, 0, []))
    var writes: Int { state.withLock { $0.writes } }
    var onMainThread: [Bool] { state.withLock { $0.onMain } }

    func readData() -> Data? { state.withLock { $0.data } }

    func write(_ data: Data) -> Bool {
        let main = Thread.isMainThread
        state.withLock { $0.data = data; $0.writes += 1; $0.onMain.append(main) }
        return true
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
