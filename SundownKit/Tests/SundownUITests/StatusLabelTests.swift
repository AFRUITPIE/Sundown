import Testing
import TetherProtocol
@testable import SundownUI

/// The inspector shows server states as words. Raw wire values reaching the user is the bug these
/// guard against, including for a status this build has never heard of.
@Suite
struct StatusLabelTests {
    @Test func threadStatusesReadAsWords() {
        #expect(ThreadStatus.notLoaded.label == "Not Loaded")
        #expect(ThreadStatus.requiresAction.label == "Requires Action")
        #expect(ThreadStatus.idle.label == "Idle")
        // Forward compatibility: unions keep unknown variants, so they have to display too.
        #expect(ThreadStatus(rawValue: "awaitingReview").label == "Awaiting Review")
    }

    @Test func serverVocabularyBecomesTitleCase() {
        #expect("needs-auth".humanized == "Needs Auth")
        #expect("task_started".humanized == "Task Started")
        #expect("connected".humanized == "Connected")
        #expect("".humanized == "")
    }
}
