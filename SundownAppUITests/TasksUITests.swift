import XCTest

/// The `tasks` scenario's chats: one that started a workflow, agents, a background command, a
/// monitor and an MCP tool, and ends with messages the person didn't type; and a second holding the
/// same, followed rather than live, as most of a host's chats are.
final class TasksUITests: SundownUITestCase {
    /// Messages the person didn't type read as quiet lines in Claude's column (#78); a followed
    /// chat picked while the Tasks tab shows is read, and lists its tasks (#109).
    @MainActor
    func testUntypedMessagesAndAFollowedChatsTasks() {
        launch("tasks")
        let prompt = text("Review the changes, and find which views read thread.items.")
        XCTAssertTrue(prompt.appears(timeout: 15), "the tasks chat never showed")

        // Claude Code's, another session's and a compaction's summary: each a line that opens to
        // the message, in Claude's column, never a prompt on the person's side.
        for label in ["Message from Claude Code", "Message from release-notes", "Summary of the earlier conversation"] {
            let line = app.disclosureTriangles.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            XCTAssertTrue(line.appears(timeout: 5), "no “\(label)” line")
            XCTAssertLessThan(line.frame.minX, prompt.frame.minX, "“\(label)” isn't in Claude's column")
        }
        XCTAssertFalse(text("The release notes are drafted.").exists, "another session's message is drawn as a prompt")
        XCTAssertTrue(text(containing: "Conversation compacted from 84").exists, "no line says the conversation was compacted")

        // The Tasks tab lists this chat's tasks; picked there, the followed chat is read and lists its own.
        paneTab("Tasks").click()
        // A task's row is one element: its state, name, kind and time, as its label or (running) its value.
        let agent = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Find every SwiftUI view", "Find every SwiftUI view")).firstMatch
        XCTAssertTrue(agent.appears(timeout: 10), "Tasks doesn't list the live chat's agent")
        row("Followed Tasks").click()
        XCTAssertTrue(waitForTitle("Followed Tasks"), "the followed chat didn't open: \(app.windows.firstMatch.title)")
        XCTAssertTrue(agent.appears(timeout: 10), "a followed chat picked while Tasks shows lists no tasks")
    }
}
