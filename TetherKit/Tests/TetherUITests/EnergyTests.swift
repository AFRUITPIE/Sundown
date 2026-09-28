import AppKit
import Foundation
import Synchronization
import Testing
import TetherKit
@testable import TetherUI

@MainActor
@Suite
struct PreferenceWriteTests {
    /// Choosing a chat or a pane writes where the last window was, under its own small key; the
    /// hosts, pins and preferences aren't written again each time.
    @Test func aChatSwitchWritesOnlyTheLastWindow() throws {
        let defaults = try #require(CountingDefaults(suiteName: "tether.tests.\(UUID().uuidString)"))
        let app = AppModel.sample(connections: [.sample()], defaults: defaults)
        let w = WindowModel(app: app, target: app.newWindowTarget())
        w.start()
        let chats = try #require(w.connection?.chats)
        defaults.keys.removeAll()

        w.open(threadID: chats[0].id)
        w.open(threadID: chats[1].id)
        w.openInspector(on: .mcp)

        #expect(!defaults.keys.contains("tether.hosts.v1"))
        #expect(defaults.keys.allSatisfy { $0 == "tether.window.v1" })
        #expect(!defaults.keys.isEmpty)

        // The same again: nothing written.
        defaults.keys.removeAll()
        app.remember(w)
        app.transcriptWidth = app.transcriptWidth
        #expect(defaults.keys.isEmpty)
    }

    /// Where the last window was moves out of an older build's store, once, and still reopens there.
    @Test func theLastWindowMovesToItsOwnKeyOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)"))
        let host = UUID()
        let old = #"{"hosts":[{"id":"\#(host.uuidString)","name":"box","kind":{"ssh":{"destination":"box"}},"env":{}}],"hostID":"\#(host.uuidString)","threadID":"t-7","showInspector":true,"inspectorPane":"changes"}"#
        defaults.set(Data(old.utf8), forKey: "tether.hosts.v1")

        let app = AppModel(defaults: defaults)
        #expect(app.lastHostID == host && app.lastThreadID == "t-7")
        #expect(app.lastShowInspector && app.lastInspectorPane == .changes)
        #expect(defaults.data(forKey: "tether.window.v1") != nil)

        // The next save of the rest leaves the old fields out; the window is still found.
        app.transcriptWidth = .wide
        let raw = String(decoding: try #require(defaults.data(forKey: "tether.hosts.v1")), as: UTF8.self)
        #expect(!raw.contains("t-7"))
        let restored = AppModel(defaults: defaults)
        #expect(restored.lastHostID == host && restored.lastThreadID == "t-7")
        #expect(restored.lastShowInspector && restored.lastInspectorPane == .changes)
    }
}

@MainActor
@Suite
struct DraftWriteTests {
    /// A save with nothing new writes nothing, and the same drafts are the same bytes, not written again.
    @Test func draftsAreWrittenOnlyWhenTheyChanged() throws {
        let defaults = try #require(UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)"))
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
        let defaults = try #require(UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)"))
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

@Suite
struct ReducedEffectsTests {
    @Test func energySavingHeatAndTheBackgroundReduceEffects() {
        #expect(!ReducedEffects.reduces(lowPower: false, thermal: .nominal, appIsActive: true))
        #expect(!ReducedEffects.reduces(lowPower: false, thermal: .fair, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: true, thermal: .nominal, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: false, thermal: .serious, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: false, thermal: .critical, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: false, thermal: .nominal, appIsActive: false))
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
