import Testing
import TetherProtocol
@testable import SundownUI

/// Server states are shown as words. Raw wire values reaching the user is the bug these guard
/// against, including for a status this build has never heard of.
@Suite
struct StatusLabelTests {
    @Test func threadStatusesReadAsWords() {
        #expect(ThreadStatus.notLoaded.rawValue.humanized == "Not Loaded")
        #expect(ThreadStatus.requiresAction.rawValue.humanized == "Requires Action")
        #expect(ThreadStatus.idle.rawValue.humanized == "Idle")
        // Forward compatibility: unions keep unknown variants, so they have to display too.
        #expect(ThreadStatus(rawValue: "awaitingReview").rawValue.humanized == "Awaiting Review")
    }

    @Test func serverVocabularyBecomesTitleCase() {
        #expect("needs-auth".humanized == "Needs Auth")
        #expect("task_started".humanized == "Task Started")
        #expect("connected".humanized == "Connected")
        #expect("".humanized == "")
    }
}
