import Foundation
import Testing
import TetherKit
import TetherProtocol
@testable import TetherUI

@MainActor
@Suite
struct AttentionTests {
    private let defaults = AlertPreferences()

    @Test func aChatInFrontOfYouIsNeverNews() {
        #expect(!AttentionCenter.shouldNotify(.needsInput, prefs: defaults, appIsActive: true, chatIsShown: true))
        #expect(!AttentionCenter.shouldNotify(.replyFinished(failed: false), prefs: defaults, appIsActive: true, chatIsShown: true))
    }

    @Test func aChatYouAreNotLookingAtIs() {
        #expect(AttentionCenter.shouldNotify(.needsInput, prefs: defaults, appIsActive: true, chatIsShown: false))
        #expect(AttentionCenter.shouldNotify(.replyFinished(failed: false), prefs: defaults, appIsActive: false, chatIsShown: true))
    }

    @Test func theSettingsDecide() {
        var prefs = AlertPreferences()
        prefs.replyFinished = .never
        prefs.needsInput = false
        #expect(!AttentionCenter.shouldNotify(.replyFinished(failed: true), prefs: prefs, appIsActive: false, chatIsShown: false))
        #expect(!AttentionCenter.shouldNotify(.needsInput, prefs: prefs, appIsActive: false, chatIsShown: false))
        prefs.replyFinished = .always
        #expect(AttentionCenter.shouldNotify(.replyFinished(failed: false), prefs: prefs, appIsActive: true, chatIsShown: true))
    }

    @Test func theBadgeCountsWhatItIsSetTo() {
        let chats = [(isRunning: true, waiting: true), (isRunning: true, waiting: false), (isRunning: false, waiting: false)]
        #expect(AttentionCenter.badgeCount(chats, badge: .waiting) == 1)
        #expect(AttentionCenter.badgeCount(chats, badge: .working) == 2)
        #expect(AttentionCenter.badgeCount(chats, badge: .off) == 0)
    }

    /// A request the daemon re-sends on every reconnect is told about once.
    @Test func aRequestIsToldAboutOnce() {
        var sightings = RequestSightings()
        let seen = ["host/req_1", "host/req_1", "host/req_2", "other/req_1"].map { sightings.firstSighting(of: $0) }
        // Another host's request is its own.
        #expect(seen == [true, false, true, true])
    }

    /// Only the oldest are forgotten, and only past the limit.
    @Test func sightingsForgetTheOldestPastTheLimit() {
        var sightings = RequestSightings()
        for i in 0...RequestSightings.limit { _ = sightings.firstSighting(of: "r\(i)") }
        let oldest = sightings.firstSighting(of: "r0")
        let newest = sightings.firstSighting(of: "r\(RequestSightings.limit)")
        #expect(oldest && !newest)
    }

    @Test func aNotificationSaysWhatIsAsked() {
        let permission = PermissionRequestParams(threadId: "t", requestId: "r", toolUseId: "u", toolName: "Bash",
                                                 input: ["command": "ls"])
        #expect(AttentionCenter.describe(.permissionRequest(permission)) == "Allow Bash?")
        #expect(AttentionCenter.describe(nil) == "Claude needs your input.")
    }

    @Test func aFinishedReplyIsSummedUpByItsLastLine() {
        let thread = ThreadModel.sample(status: .idle, items: [
            .sampleUserMessage("Fix it", secondsAgo: 10),
            .agentMessage(.sample("## Done\n\nI fixed the **layout loop**.\nAll tests pass.", secondsAgo: 2)),
        ])
        #expect(AttentionCenter.lastReplyLine(thread) == "All tests pass.")
    }

    @Test func preferencesAreKept() {
        let store = UserDefaults(suiteName: "tether.tests.\(UUID().uuidString)")!
        let app = AppModel(defaults: store)
        app.alerts.dockBadge = .working
        app.alerts.sound = false
        let restored = AppModel(defaults: store).alerts
        #expect(restored.dockBadge == .working)
        #expect(!restored.sound)
        #expect(restored.needsInput)
    }
}
