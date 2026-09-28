import Testing
import TetherProtocol
@testable import TetherKit

@Suite
struct PromptNavigationTests {
    private func prompt(_ id: String, synthetic: Bool = false) -> TranscriptRow {
        .item(.userMessage(.init(id: id, createdAt: 1, content: [.text(.init(text: "go"))], synthetic: synthetic ? true : nil)))
    }

    private func reply(_ id: String) -> TranscriptRow {
        .item(.agentMessage(.init(id: id, createdAt: 1, text: "done")))
    }

    /// p1 (with its date), m1, p2, m2, a synthetic message, p3, m3.
    private var rows: [TranscriptRow] {
        [.dateSeparator(promptID: "p1", ms: 1), prompt("p1"), reply("m1"), prompt("p2"), reply("m2"),
         prompt("s1", synthetic: true), prompt("p3"), reply("m3")]
    }

    /// A prompt with a date is reached by its date, so the date comes into view with it; a message
    /// that didn't come from the reader isn't a stop.
    @Test func targetsAreTheReadersPrompts() {
        #expect(PromptNavigation.targets(in: rows).map(\.id) == ["date-p1", "p2", "p3"])
    }

    /// From the middle of a reply, Previous goes to that turn's prompt and Next to the next one.
    @Test func fromAReplyOnScreen() {
        let visible: Set = ["m2", "s1"]
        #expect(PromptNavigation.target(.previous, rows: rows, visible: visible) == "p2")
        #expect(PromptNavigation.target(.next, rows: rows, visible: visible) == "p3")
    }

    /// Pressed again, it goes on from the prompt it went to, even with the row above it on screen.
    @Test func goesOnFromTheLastPrompt() {
        let visible: Set = ["m1", "p2", "m2"]
        #expect(PromptNavigation.target(.next, rows: rows, visible: visible, lastTarget: "p2") == "p3")
        #expect(PromptNavigation.target(.previous, rows: rows, visible: visible, lastTarget: "p2") == "date-p1")
    }

    /// Pressed again before the scroll to the last one has landed, it still goes on from there
    /// rather than going back to the same prompt.
    @Test func goesOnBeforeTheScrollLands() {
        #expect(PromptNavigation.target(.previous, rows: rows, visible: ["m3"], lastTarget: "p2") == "date-p1")
        #expect(PromptNavigation.target(.next, rows: rows, visible: ["m1"], lastTarget: "p2") == "p3")
    }

    /// An older page can take away the date gone to; the prompt under it stands in.
    @Test func goesOnFromAPromptWhoseDateWent() {
        let undated = rows.filter { $0.id != "date-p1" }
        #expect(PromptNavigation.target(.next, rows: undated, visible: ["m3"], lastTarget: "date-p1") == "p2")
    }

    @Test func nothingBeyondTheEnds() {
        #expect(PromptNavigation.target(.previous, rows: rows, visible: ["date-p1", "p1"]) == nil)
        #expect(PromptNavigation.target(.next, rows: rows, visible: ["p3", "m3"]) == nil)
    }

    /// Before anything has been on screen, Previous goes to the last prompt.
    @Test func withNothingOnScreen() {
        #expect(PromptNavigation.target(.previous, rows: rows, visible: []) == "p3")
        #expect(PromptNavigation.target(.next, rows: rows, visible: []) == nil)
        #expect(PromptNavigation.target(.previous, rows: [], visible: []) == nil)
    }
}
