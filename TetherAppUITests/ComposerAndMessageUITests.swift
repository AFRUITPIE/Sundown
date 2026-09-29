import AppKit
import XCTest

/// The composer's buttons, what can be done with a message, and how a tool call's row reads.
final class ComposerAndMessageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    private func launch(scenario: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        if let scenario { app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        return app
    }

    /// The on-screen item with this title: the menu bar lists some of the same commands, off screen.
    @MainActor
    private func visibleMenuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let items = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        _ = items.firstMatch.waitForExistence(timeout: 5)
        return items.allElementsBoundByIndex.first { $0.isHittable } ?? items.firstMatch
    }

    @MainActor
    func testSendIsAvailableOnlyWithSomethingToSend() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any)["composer.input"]
        let send = app.buttons["composer.send"]
        XCTAssertFalse(send.isEnabled)

        input.click()
        input.typeText("Hello")
        XCTAssertTrue(send.isEnabled)

        input.typeKey("a", modifierFlags: .command)
        input.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(send.isEnabled)

        // Whitespace alone isn't a message.
        input.typeText("   ")
        XCTAssertFalse(send.isEnabled)
    }

    /// The round + beside the field is a menu; Attach Files… opens the Open panel, and Mention a
    /// File starts an @ mention.
    @MainActor
    func testAddOpensTheFilePanel() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let add = app.descendants(matching: .any)["composer.add"].firstMatch
        XCTAssertTrue(add.exists)
        add.click()
        visibleMenuItem(app, "Mention a File").click()
        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertEqual(input.value as? String, "@")

        add.click()
        visibleMenuItem(app, "Attach Files…").click()

        let panel = app.sheets.firstMatch
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5) || dialog.waitForExistence(timeout: 1), "no Open panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    /// A button in the window, not its Touch Bar copy, once it appears.
    @MainActor
    private func windowButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let buttons = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let button = buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) { return button }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return buttons.firstMatch
    }

    /// Copy is on the bar that appears over a message on hover, and in its context menu.
    @MainActor
    func testCopyingAMessage() {
        let app = launch()
        let prompt = app.staticTexts["Summarize this project"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        NSPasteboard.general.clearContents()

        prompt.hover()
        let fork = windowButton(app, "Fork from Here")
        XCTAssertTrue(fork.waitForExistence(timeout: 5))
        let forkBefore = fork.frame
        windowButton(app, "Copy").click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Summarize this project")
        // Turning into a checkmark, for a second, doesn't resize the bar: the buttons after Copy stay
        // where they were. Read once the symbol has turned.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(fork.frame.minX, forkBefore.minX, accuracy: 0.5)

        // A reply copies from its hover bar the same way. (Its text spans the reply's width, so
        // right-clicking it gives the text's own menu rather than the message's.)
        NSPasteboard.general.clearContents()
        let answer = app.staticTexts["Fixture answer from the local transport."].firstMatch
        answer.hover()
        windowButton(app, "Copy").click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Fixture answer from the local transport.")
    }

    /// Fork from Here makes a new chat from the conversation so far and opens it.
    @MainActor
    func testForkFromHereOpensTheFork() {
        let app = launch()
        let answer = app.staticTexts["Fixture answer from the local transport."].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        if !app.outlines["Sidebar"].exists { app.menuBars.menuItems["toggleSidebar:"].click() }
        let outline = app.outlines["Sidebar"]
        let rows = outline.outlineRows.containing(.staticText, identifier: "Fixture Chat")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)

        answer.hover()
        windowButton(app, "Fork from Here").click()

        let deadline = Date().addingTimeInterval(5)
        while rows.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(rows.count, 2)
        // The fork is the newer chat, so it heads the list, and it's the one showing.
        XCTAssertTrue(rows.element(boundBy: 0).isSelected)
        XCTAssertFalse(rows.element(boundBy: 1).isSelected)
    }

    /// A running call reads as a button that says it's running, and stops saying so when it
    /// finishes. Its spinner used to make the whole row read as a progress indicator.
    @MainActor
    func testARunningCallReadsAsRunning() {
        let app = launch(scenario: "performance")
        XCTAssertTrue(app.staticTexts["Section 29: tightening the renderer"].firstMatch.waitForExistence(timeout: 20))
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Keep going")
        app.buttons["composer.send"].click()

        // A disclosure triangle's value is whether it's open: the status follows the row's words.
        let running = app.windows.firstMatch.disclosureTriangles.matching(NSPredicate(format: "label ENDSWITH 'Running'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 10))
        XCTAssertTrue(running.waitForNonExistence(timeout: 10))
    }

    /// Restore Code to Here… says which files go back before doing it, and then can't again.
    @MainActor
    func testRestoreCodeConfirmsFirst() {
        let app = launch()
        let prompt = app.staticTexts["Summarize this project"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))

        // In the blank beside the bubble: its words are selectable text, with the text's own menu.
        let besidePrompt = prompt.coordinate(withNormalizedOffset: CGVector(dx: -0.6, dy: 0.5))
        besidePrompt.rightClick()
        visibleMenuItem(app, "Restore Code to Here…").click()
        XCTAssertTrue(app.staticTexts["Restore Files to Before This Message?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'App.swift, README.md'")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'App.swift, README.md'")).firstMatch.exists)
        windowButton(app, "Restore").click()
        XCTAssertTrue(app.staticTexts["Restore Files to Before This Message?"].waitForNonExistence(timeout: 5))

        besidePrompt.rightClick()
        visibleMenuItem(app, "Restore Code to Here…").click()
        XCTAssertTrue(app.staticTexts["No Files to Restore"].waitForExistence(timeout: 5))
        windowButton(app, "OK").click()
    }

    /// The Changes pane lists what differs from the last commit; a comment on a line goes to Claude.
    @MainActor
    func testCommentingOnAChangeSendsIt() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        app.typeKey("4", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["App.swift"].waitForExistence(timeout: 10))

        // Each line is a button, its text the value; the comment is written in a popover beside it.
        let changed = app.buttons.matching(NSPredicate(format: "value == %@", "let greeting = \"Hello, Tether\"")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 5))
        changed.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        let field = popover.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Use the app's name from its bundle")
        popover.buttons["Add"].click()

        let send = app.windows.firstMatch.buttons["Send Comment"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        // By its leading edge: on CI's 1024-point screen the window, with the inspector open, is
        // wider than the screen, and the button's middle is off it.
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Sources/App.swift:2' OR label CONTAINS 'Sources/App.swift:2'")).firstMatch.waitForExistence(timeout: 10))
    }

    /// ⌥⌘; asks a side question: answered in the sheet, not added to the chat.
    @MainActor
    func testASideQuestionStaysOutOfTheChat() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        app.typeKey(";", modifierFlags: [.command, .option])
        let field = app.descendants(matching: .any)["sideQuestion.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("What did we decide?")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'A side answer' OR label CONTAINS 'A side answer'")).firstMatch.waitForExistence(timeout: 5))
        windowButton(app, "Done").click()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'What did we decide?' OR label CONTAINS 'What did we decide?'")).firstMatch.exists)
    }

    /// A task Claude suggests is a button above the composer; it starts a new chat with its prompt.
    @MainActor
    func testASuggestedTaskStartsANewChat() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Please suggest a task")
        input.typeKey(.return, modifierFlags: [])

        let chip = windowButton(app, "Write the release notes")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.click()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5))
        // New Chat, with Claude's prompt as a draft to read before sending.
        let draft = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(NSPredicate(format: "value CONTAINS 'release notes'").evaluate(with: draft))
    }
}
