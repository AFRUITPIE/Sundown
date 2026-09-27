import Foundation
import Testing
import TetherKit
@testable import TetherUI

@MainActor
@Suite
struct WindowModelTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)")!
    }

    private func window(_ app: AppModel, target: WindowTarget? = nil) -> WindowModel {
        let window = WindowModel(app: app, target: target)
        window.start()
        return window
    }

    @Test func opensOnANewLocalChat() {
        let w = window(AppModel(defaults: isolatedDefaults()))

        #expect(w.hostID == HostConfig.local.id)
        #expect(w.threadID == nil)
        #expect(w.selectedThread == nil)
    }

    @Test func selectingAChatResolvesItOnTheCurrentHost() {
        let w = window(AppModel(defaults: isolatedDefaults()))

        w.open(threadID: "thread-1")

        #expect(w.threadID == "thread-1")
        #expect(w.selectedThread?.id == "thread-1")
        // The same identity every time, or subscriptions and pending prompts would be lost.
        let again = w.selectedThread
        w.threadID = "thread-1"
        #expect(w.selectedThread === again)
    }

    @Test func nothingResolvesBeforeTheWindowStarts() {
        let app = AppModel(defaults: isolatedDefaults())
        let w = WindowModel(app: app, target: WindowTarget(hostID: HostConfig.local.id, threadID: "thread-1"))
        #expect(w.selectedThread == nil)
        #expect(app.openWindows.isEmpty)
        w.start()
        #expect(w.selectedThread?.id == "thread-1")
        #expect(app.openWindows.count == 1)
    }

    @Test func newChatKeepsTheSelectedHost() {
        let w = window(AppModel(defaults: isolatedDefaults()))
        w.open(threadID: "thread-1")

        w.newChat()

        #expect(w.hostID == HostConfig.local.id)
        #expect(w.threadID == nil)
        #expect(w.selectedThread == nil)
    }

    @Test func newChatStartsInTheHostsMostRecentFolder() {
        let w = window(.sample())
        let first = w.connection?.projects.first?.cwd
        #expect(first != nil)
        #expect(w.draftDirectory == first)
        w.draftError = "Choose a folder first."

        w.newChat()

        #expect(w.draftDirectory == first)
        #expect(w.draftError == nil)
    }

    @Test func subtitleIsTheFolderNameWithOneHost() {
        let w = window(.sample())
        #expect(w.draftDirectory != nil)
        #expect(w.subtitle == (w.draftDirectory as NSString?)?.lastPathComponent)
    }

    @Test func subtitleNamesTheHostWhenThereAreSeveral() {
        let w = window(.sample(connections: [.sample(), .sampleFailed()]))
        let name = (w.draftDirectory as NSString?)?.lastPathComponent ?? ""
        #expect(w.subtitle == "\(w.host?.name ?? "") · \(name)")

        // A host with no projects yet: the host alone, not a dangling separator.
        w.hostID = w.app.hosts[1].id
        #expect(w.draftDirectory == nil)
        #expect(w.subtitle == "staging")
    }

    @Test func subtitleFollowsTheOpenChatsFolder() {
        let w = window(.sample())
        guard let chat = w.connection?.chats.first(where: { $0.cwd != nil }) else {
            Issue.record("the sample host has no chat with a folder")
            return
        }
        w.open(threadID: chat.id)
        #expect(w.subtitle == (chat.cwd! as NSString).lastPathComponent)
    }

    @Test func switchingHostClearsTheSelectedChat() {
        let w = window(.sample(connections: [.sample(), .sampleFailed()]))
        let other = w.app.hosts[1].id
        w.open(threadID: "thread-1")

        w.hostID = other

        #expect(w.threadID == nil)
        #expect(w.selectedThread == nil)
    }

    @Test func removingTheCurrentHostFallsBackToLocal() {
        let app = AppModel.sample(connections: [.sample(), .sampleFailed()])
        let w = window(app)
        let other = app.hosts[1].id
        w.hostID = other
        w.open(threadID: "thread-1")

        app.removeHost(other)

        #expect(w.hostID == HostConfig.local.id)
        #expect(w.threadID == nil)
        #expect(w.connection?.host.id == HostConfig.local.id)
    }

    @Test func aHostThatIsGoneFallsBackToLocal() {
        let w = window(AppModel(defaults: isolatedDefaults()))

        w.hostID = UUID()

        #expect(w.hostID == HostConfig.local.id)
    }

    /// Two windows are two selections: each shows its own chat and inspector.
    @Test func windowsKeepTheirOwnSelection() {
        let app = AppModel.sample()
        let a = window(app), b = window(app)
        let chats = app.connection(app.lastHostID)?.chats ?? []
        #expect(chats.count >= 2)

        a.open(threadID: chats[0].id)
        b.open(threadID: chats[1].id)
        b.showInspector = true

        #expect(a.selectedThread === chats[0])
        #expect(b.selectedThread === chats[1])
        #expect(!a.showInspector)
    }

    /// A chat shown in two windows stays loaded until the last one moves off it.
    @Test func aChatIsLetGoOnlyWhenNoWindowShowsIt() {
        let app = AppModel.sample()
        let a = window(app), b = window(app)
        a.open(threadID: "shared")
        b.open(threadID: "shared")
        #expect(a.selectedThread === b.selectedThread)

        a.newChat()
        #expect(app.isShown(b.selectedThread))
        b.close()
        #expect(!app.isShown(a.connection?.thread("shared")))
    }

    @Test func aNewWindowOpensWhereTheLastOneWas() {
        let app = AppModel.sample()
        let a = window(app)
        a.open(threadID: "thread-1")
        a.openInspector(on: .mcp)

        let b = window(app)

        #expect(b.threadID == "thread-1")
        #expect(b.isInspecting(.mcp))
        // A window opened on a target starts there instead.
        let c = window(app, target: WindowTarget(hostID: app.lastHostID))
        #expect(c.threadID == nil)
    }

    @Test func theLastChatReopensAfterRelaunch() {
        let defaults = isolatedDefaults()
        let app = AppModel.sample(connections: [.sample(), .sampleFailed()], defaults: defaults)
        let w = window(app)
        let other = app.hosts[1].id
        w.hostID = other
        w.open(threadID: "thread-9")
        w.showInspector = true
        w.inspectorPane = .mcp

        let restored = window(AppModel(defaults: defaults))

        #expect(restored.hostID == other)
        #expect(restored.threadID == "thread-9")
        #expect(restored.isInspecting(.mcp))
    }

    @Test func draftsArePerChatAndSurviveRelaunch() {
        let defaults = isolatedDefaults()
        let app = AppModel(defaults: defaults)
        app.setDraft("half a thought", for: "a")
        app.setDraft("another", for: "b")
        app.setDraft("   ", for: "b")

        let restored = AppModel(defaults: defaults)

        #expect(restored.draft(for: "a") == "half a thought")
        // Whitespace alone isn't a draft.
        #expect(restored.draft(for: "b") == "")
    }

    @Test func defaultsRoundTripWithoutUsingStandardDefaults() {
        let defaults = isolatedDefaults()
        let app = AppModel.sample(connections: [.sample(), .sampleFailed()], defaults: defaults)
        app.defaultModel = "sonnet"
        app.defaultEffort = "high"
        app.defaultPermissionMode = "plan"
        app.transcriptWidth = .wide
        app.sidebarGrouping = .directory

        let restored = AppModel(defaults: defaults)

        #expect(restored.defaultModel == "sonnet")
        #expect(restored.defaultEffort == "high")
        #expect(restored.defaultPermissionMode == "plan")
        #expect(restored.transcriptWidth == .wide)
        #expect(restored.sidebarGrouping == .directory)
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
        #expect(!app.lastShowInspector)
        #expect(app.lastInspectorPane == .tasks)
        #expect(app.sidebarGrouping == .date)
        #expect(app.lastHostID == HostConfig.local.id)
    }

    @Test func aPaneShortcutShowsItsPaneAndOpensTheInspector() {
        let w = window(AppModel(defaults: isolatedDefaults()))
        w.openInspector(on: .session)
        #expect(w.isInspecting(.session))
        w.openInspector(on: .session)
        #expect(w.isInspecting(.session))
        w.showInspector = false
        // The pane is kept, so ⌥⌘I reopens where the inspector was.
        #expect(w.inspectorPane == .session)
    }

    /// ⌃⇥ and ⌃⇧⇥ step through the chats in the sidebar's order, wrapping at the ends.
    @Test func nextAndPreviousChatFollowTheSidebar() {
        let w = window(.sample())
        let order = sidebarSections(chats: (w.connection?.chats ?? []).map {
            SidebarChat(id: $0.id, title: $0.title, cwd: $0.cwd, updatedAt: $0.summary?.updatedAt)
        }, grouping: .date).flatMap { $0.chats.map(\.id) }
        #expect(order.count >= 2)

        #expect(w.adjacentChat(1) == order.first)
        w.showAdjacentChat(1)
        #expect(w.threadID == order[0])
        w.showAdjacentChat(1)
        #expect(w.threadID == order[1])
        w.showAdjacentChat(-1)
        w.showAdjacentChat(-1)
        #expect(w.threadID == order.last)
    }

    /// Pins are per host, survive a relaunch, and go with a host that's removed.
    @Test func pinsArePerHostAndSurviveRelaunch() {
        let defaults = isolatedDefaults()
        let ssh = HostConnection.sampleFailed()
        let app = AppModel.sample(connections: [.sample(), ssh], defaults: defaults)
        app.setPinned(true, "a", on: HostConfig.local.id)
        app.setPinned(true, "b", on: HostConfig.local.id)
        app.setPinned(false, "b", on: HostConfig.local.id)
        app.setPinned(true, "c", on: ssh.id)

        let restored = AppModel(defaults: defaults)

        #expect(restored.isPinned("a", on: HostConfig.local.id))
        #expect(!restored.isPinned("b", on: HostConfig.local.id))
        #expect(restored.isPinned("c", on: ssh.id))
        #expect(!restored.isPinned("c", on: HostConfig.local.id))

        restored.removeHost(ssh.id)
        #expect(AppModel(defaults: defaults).pinnedChats[ssh.id] == nil)
    }

    /// Chat ▸ Pin moves the chat into Pinned, and ⌃⇥ follows the sidebar with it on top.
    @Test func pinningMovesAChatToTheTopOfTheSidebar() {
        let w = window(.sample())
        let chats = w.connection?.chats ?? []
        let oldest = chats.min { ($0.summary?.updatedAt ?? .infinity) < ($1.summary?.updatedAt ?? .infinity) }!
        #expect(!w.isPinned(oldest))

        w.togglePin(oldest)

        #expect(w.isPinned(oldest))
        let sections = w.sidebarList(w.sidebarThreads)
        #expect(sections.first?.title == "Pinned")
        #expect(sections.first?.chats.map(\.id) == [oldest.id])
        #expect(sections.dropFirst().allSatisfy { !$0.chats.contains { $0.id == oldest.id } })
        #expect(w.adjacentChat(1) == oldest.id)

        w.togglePin(oldest)
        #expect(w.sidebarList(w.sidebarThreads).first?.title != "Pinned")
    }

    /// Bypass Permissions is listed only when Settings offers it, or while a chat is in it.
    @Test func bypassStaysListedWhileChosen() {
        let app = AppModel.sample()
        let w = window(app)
        app.appearance.offerBypass = false
        var settings = SessionSettings.current(w)
        #expect(!settings.offeredModes.contains(.bypassPermissions))
        #expect(settings.offeredModes.contains(.dontAsk))

        w.draftPermissionMode = .bypassPermissions
        settings = SessionSettings.current(w)
        #expect(settings.offeredModes.contains(.bypassPermissions))
    }

    @Test func newChatsStartInAWorktreeWhenSettingsSaySo() {
        let app = AppModel.sample()
        let w = window(app)
        #expect(!w.draftWorktree)
        app.appearance.worktreeByDefault = true
        w.newChat()
        #expect(w.draftWorktree)
    }

    @Test func newChatCanStartWithNoFolder() {
        let app = AppModel.sample()
        app.appearance.newChatFolder = .ask
        let w = window(app)
        w.newChat()
        #expect(w.draftDirectory == nil)
    }

    @Test func newChatUsesTheConfiguredDefaults() {
        let app = AppModel(defaults: isolatedDefaults())
        let w = window(app)
        app.defaultModel = "sonnet"
        app.defaultEffort = "high"
        app.defaultPermissionMode = "plan"

        w.newChat()

        #expect(w.draftModel == "sonnet")
        #expect(w.draftEffort == .high)
        #expect(w.draftPermissionMode == .plan)
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
