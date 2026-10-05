import XCTest

/// Claude's requests, as cards over the composer, against the fixture's `prompts` scenario: a
/// permission, a second one, a question, a form and a very long question, each asked once the one
/// before is answered, each answer said in the chat ("Answered: " and its JSON).
final class PromptCardsUITests: TetherUITestCase {
    @MainActor
    func testAnsweringEachKindOfRequest() {
        launch("prompts")
        let permission = app.staticTexts["Allow fixture command?"]
        XCTAssertTrue(permission.appears(timeout: 15), "no permission card")
        let send = app.buttons["composer.send"]
        // In the window: not a Touch Bar's copy of the card's buttons.
        let buttons = app.windows.firstMatch.buttons

        // The composer stays under a card, so a draft survives it, but can't send until it's
        // answered; and Return in the draft doesn't press the card's default button, Allow.
        input.click()
        input.typeText("Draft survives permission")
        XCTAssertFalse(send.isEnabled, "Send is enabled while a request waits")
        for _ in 0..<3 { input.typeKey(.return, modifierFlags: []) }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(permission.exists, "Return in the draft answered the request")
        XCTAssertFalse(text(containing: "Answered: ").exists, "Return in the draft answered the request")
        // Deny… asks what to do instead; Deny answers.
        buttons["Deny…"].clickWhenReady()
        buttons["Deny"].clickWhenReady()
        XCTAssertTrue(permission.disappears(timeout: 5), "Deny left the card")
        XCTAssertTrue(text(containing: #""decision":"deny""#).appears(timeout: 5), "Deny didn't answer deny")
        XCTAssertTrue(inputText().contains("Draft survives permission"), "the draft was lost: \(inputText())")

        // Allow.
        let second = app.staticTexts["Allow second command?"]
        XCTAssertTrue(second.appears(timeout: 5), "no second permission card")
        buttons["Allow"].clickWhenReady()
        XCTAssertTrue(second.disappears(timeout: 5), "Allow left the card")
        XCTAssertTrue(text(containing: #""decision":"allow""#).appears(timeout: 5), "Allow didn't answer allow")

        // A question: Submit waits for a choice, then answers with it.
        let question = app.staticTexts["Claude Has a Question"]
        XCTAssertTrue(question.appears(timeout: 5), "no question card")
        let submit = buttons["Submit"]
        XCTAssertFalse(submit.isEnabled, "Submit is enabled with nothing chosen")
        app.radioButtons["SQLite"].clickWhenReady()
        XCTAssertTrue(waitUntil(3) { submit.isEnabled }, "Submit is disabled with a choice made")
        submit.clickWhenReady()
        XCTAssertTrue(question.disappears(timeout: 5), "Submit left the question")
        XCTAssertTrue(text(containing: #""SQLite""#).appears(timeout: 5), "the answer isn't the choice")

        // A form (an MCP server's elicitation): Continue waits for its required field.
        let form = app.staticTexts["Fixture Server Needs Input"]
        XCTAssertTrue(form.appears(timeout: 5), "no form card")
        let next = buttons["Continue"]
        XCTAssertFalse(next.isEnabled, "Continue is enabled with a required field empty")
        let name = app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Project Name", "Project Name")).firstMatch
        XCTAssertTrue(name.exists, "the form has no Project Name field")
        name.clickWhenReady()
        name.typeText("Tether")
        XCTAssertTrue(waitUntil(3) { next.isEnabled }, "Continue is disabled with the required field filled")
        next.clickWhenReady()
        XCTAssertTrue(form.disappears(timeout: 5), "Continue left the form")
        XCTAssertTrue(text(containing: #""name":"Tether""#).appears(timeout: 5), "the form's answer isn't what was typed")

        // A question far longer than the window still has to be answerable.
        XCTAssertTrue(question.appears(timeout: 5), "no long question card")
        let skip = buttons["Skip"]
        XCTAssertTrue(skip.exists, "the long question has no Skip")
        XCTExpectFailure("A question taller than the window pushes its Skip and Submit out of it; no scrolling reaches them", options: nonStrict) {
            XCTAssertTrue(app.windows.firstMatch.frame.contains(skip.frame), "Skip is outside the window: \(skip.frame)")
        }
        assertAlive("with a long question showing")
    }
}
