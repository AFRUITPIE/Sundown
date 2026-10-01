import XCTest

/// The message field and what's sent from it, in the short fixture chat.
final class ComposerUITests: TetherUITestCase {
    /// Send only with something to send; `/` completions; the + menu; Shift-Return, Return and a
    /// long wrapped prompt landing readable; a suggested task starting a new chat.
    @MainActor
    func testComposingAndSending() {
        launch()
        XCTAssertTrue(text(fixtureAnswer).waitForExistence(timeout: 15), "the fixture chat never showed")
        // Prompts are dated, as in Messages (when and how: DateSeparatorsTests, TranscriptDateTests).
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "transcript.date").firstMatch.waitForExistence(timeout: 5), "the prompt has no date above it")

        // Send is available only with something to send. Add and Send are circles of one size.
        let send = app.buttons["composer.send"]
        XCTAssertFalse(send.isEnabled, "Send is enabled with nothing to send")
        let add = app.descendants(matching: .any)["composer.add"].firstMatch
        XCTAssertEqual(add.frame.width, add.frame.height, accuracy: 1, "Add should be circular")
        XCTAssertEqual(send.frame.width, send.frame.height, accuracy: 1, "Send should be circular")
        XCTAssertEqual(add.frame.height, send.frame.height, accuracy: 1, "Composer actions should share a diameter")
        input.click()
        input.typeText("Hello")
        XCTAssertTrue(send.isEnabled, "Send is disabled with a message in the field")
        input.typeKey("a", modifierFlags: .command)
        input.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(send.isEnabled, "Send is enabled once the field is emptied")
        input.typeText("   ")
        XCTAssertFalse(send.isEnabled, "whitespace alone isn't a message")

        // Commands complete above the field, never in a window below it, and never send.
        input.typeKey("a", modifierFlags: .command)
        input.typeText("/")
        let compact = app.buttons["composer.completion./compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5), "typing / offers no commands")
        XCTAssertLessThan(compact.frame.maxY, input.frame.minY, "the completions aren't above the field")
        XCTAssertEqual(app.popovers.count, 0, "the completions opened a popover")
        // Typing narrows the list; a click inserts the command. The menu floats outside the
        // composer's frame, which XCUITest reads as clipping it; the pointer clicks it all the same.
        input.typeText("sta")
        let status = app.buttons["composer.completion./status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3), "/sta doesn't offer /status")
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(input.value as? String, "/status ", "clicking a completion")
        // The arrow keys choose, Tab inserts.
        input.typeKey("a", modifierFlags: .command)
        input.typeText("/")
        XCTAssertTrue(compact.waitForExistence(timeout: 3))
        input.typeKey(.downArrow, modifierFlags: [])
        input.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(input.value as? String, "/context ", "↓ then Tab")
        XCTAssertTrue(compact.waitForNonExistence(timeout: 3), "the completions stayed open after Tab")
        XCTAssertFalse(app.staticTexts["/context"].exists, "Tab sent the command")
        // Esc closes them, leaving the text.
        input.typeKey("a", modifierFlags: .command)
        input.typeText("/")
        XCTAssertTrue(compact.waitForExistence(timeout: 3))
        input.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(compact.waitForNonExistence(timeout: 3), "Esc didn't close the completions")
        XCTAssertEqual(input.value as? String, "/", "Esc changed the text")

        // The round + is a menu: Mention a File starts an @ mention, Attach Files… opens the Open panel.
        input.typeKey(.delete, modifierFlags: [])
        add.click()
        visibleMenuItem("Mention a File").click()
        XCTAssertEqual(input.value as? String, "@", "Mention a File")
        add.click()
        visibleMenuItem("Attach Files…").click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5) || app.dialogs.firstMatch.waitForExistence(timeout: 1), "no Open panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Esc didn't close the Open panel")

        // Shift-Return starts a line and Return sends. The first line wraps: a wrapped prompt keeps
        // its final text layout while its glass surface travels, and lands inside the window.
        let first = "Keep this longer message readable as it lifts from the composer, wraps across several lines, and settles into the transcript."
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeKey(.delete, modifierFlags: [])
        input.typeText(first)
        input.typeKey(.return, modifierFlags: .shift)
        input.typeText("second line")
        let prompt = first + "\nsecond line"
        XCTAssertTrue(inputText().contains(prompt), "Shift-Return didn't start a new line: \(inputText())")
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10), "Return didn't send")
        // Sending must finish: the new message's actions become usable after the spring settles.
        let copy = app.buttons["message.copy.fixture-sent-1"]
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 5), .completed, "the sent prompt's actions never became usable")
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", prompt, prompt)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "the sent prompt isn't in the transcript")
        XCTAssertGreaterThan(message.frame.height, 40, "the sent prompt isn't wrapped")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(message.frame.minX, window.minX, "the sent prompt starts outside the window")
        XCTAssertLessThanOrEqual(message.frame.maxX, window.maxX, "the sent prompt ends outside the window")

        // A task Claude suggests is a button above the composer; it starts a new chat with its
        // prompt as a draft to read before sending.
        input.click()
        input.typeText("Please suggest a task")
        input.typeKey(.return, modifierFlags: [])
        let chip = app.windows.firstMatch.buttons["Write the release notes"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no suggested task")
        chip.click()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "the suggested task stayed")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(inputText().contains("release notes"), "New Chat's draft isn't the suggested prompt: \(inputText())")
    }
}
