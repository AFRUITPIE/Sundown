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

    /// The round + beside the field opens the Open panel, for images and files to mention.
    @MainActor
    func testAddOpensTheFilePanel() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let add = app.buttons["composer.add"]
        XCTAssertTrue(add.exists)
        add.click()

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
        windowButton(app, "Copy").click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Summarize this project")

        // A reply offers its Markdown too, from the blank beside its last line: right-clicking the
        // words gives the text's own menu.
        // The first match is the reply's full width; its words are a shorter element inside it.
        let answer = app.staticTexts["Fixture answer from the local transport."].firstMatch
        answer.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).rightClick()
        visibleMenuItem(app, "Copy as Markdown").click()
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

        let running = app.windows.firstMatch.buttons.matching(NSPredicate(format: "value == 'Running'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 10))
        XCTAssertTrue(running.waitForNonExistence(timeout: 10))
    }

    /// Restore Code to Here… says which files go back before doing it, and then can't again.
    @MainActor
    func testRestoreCodeConfirmsFirst() {
        let app = launch()
        let prompt = app.staticTexts["Summarize this project"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))

        prompt.rightClick()
        visibleMenuItem(app, "Restore Code to Here…").click()
        XCTAssertTrue(app.staticTexts["Restore Files to Before This Message?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'App.swift, README.md'")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'App.swift, README.md'")).firstMatch.exists)
        windowButton(app, "Restore").click()
        XCTAssertTrue(app.staticTexts["Restore Files to Before This Message?"].waitForNonExistence(timeout: 5))

        prompt.rightClick()
        visibleMenuItem(app, "Restore Code to Here…").click()
        XCTAssertTrue(app.staticTexts["No Files to Restore"].waitForExistence(timeout: 5))
        windowButton(app, "OK").click()
    }
}
