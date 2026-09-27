import XCTest

/// Settings ▸ Appearance: each choice changes the chat beside it at once, and is kept.
final class AppearanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    private func launch(scenario: String? = "performance", defaults suite: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        if let scenario { app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario }
        if let suite { app.launchEnvironment["TETHER_UI_TEST_DEFAULTS"] = suite }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        return app
    }

    @MainActor
    private func waitForLongChat(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Section 29: tightening the renderer"].firstMatch.waitForExistence(timeout: 20))
    }

    /// Settings, on its Appearance pane.
    @MainActor
    private func openAppearance(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        let sidebar = settings.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts["Appearance"].waitForExistence(timeout: 10))
        sidebar.staticTexts["Appearance"].click()
        XCTAssertTrue(settings.staticTexts["Tool Calls"].waitForExistence(timeout: 5))
        return settings
    }

    /// A toggle in Settings by its label, whichever control type it's exposed as.
    @MainActor
    private func toggle(_ settings: XCUIElement, _ label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@ OR title == %@", label, label)
        for query in [settings.switches, settings.checkBoxes] {
            let match = query.matching(predicate).firstMatch
            if match.exists { return match }
        }
        return settings.switches.matching(predicate).firstMatch
    }

    @MainActor
    private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? ((element.value as? String) == "1")
    }

    /// Chooses `option` from the pop-up labelled `label`.
    @MainActor
    private func choose(_ settings: XCUIElement, _ label: String, _ option: String) {
        let popUp = settings.popUpButtons.matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "no \(label) pop-up")
        popUp.scrollToVisible()
        popUp.click()
        settings.menuItems[option].click()
    }

    /// Clicks the segment labelled `option`.
    @MainActor
    private func segment(_ settings: XCUIElement, _ option: String, in group: String? = nil) {
        let button: XCUIElement
        if let group {
            button = settings.radioGroups.matching(NSPredicate(format: "label == %@", group)).firstMatch.radioButtons[option]
        } else {
            button = settings.radioButtons[option].firstMatch
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(option) segment")
        button.scrollToVisible()
        button.click()
    }

    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier != 'com_apple_SwiftUI_Settings_window'")).firstMatch
    }

    /// Turning grouping off puts every finished call on a row of its own.
    @MainActor
    func testFinishedCallsCanBeUngrouped() {
        let app = launch()
        waitForLongChat(app)
        let groups = mainWindow(app).buttons.matching(NSPredicate(format: "label BEGINSWITH 'Used '"))
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5))

        let settings = openAppearance(app)
        let grouping = toggle(settings, "Group Finished Calls")
        XCTAssertTrue(isOn(grouping))
        grouping.scrollToVisible()
        grouping.click()

        XCTAssertTrue(groups.firstMatch.waitForNonExistence(timeout: 5))
        grouping.click()
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5))
    }

    /// Timestamps: none by default, under every message with Always.
    @MainActor
    func testTimestampsCanShowUnderEveryMessage() {
        let app = launch()
        waitForLongChat(app)
        let times = mainWindow(app).descendants(matching: .any).matching(identifier: "message.time")
        XCTAssertEqual(times.count, 0)

        choose(openAppearance(app), "Timestamps", "Always")

        XCTAssertTrue(times.firstMatch.waitForExistence(timeout: 5))
    }

    /// A prompt in a bubble sits at the trailing edge; plain, it starts at the column's leading edge
    /// with the reply under it.
    @MainActor
    func testPlainPromptsStartAtTheLeadingEdge() {
        let app = launch()
        waitForLongChat(app)
        let window = mainWindow(app)
        let prompt = window.staticTexts["Step 29: look at the next part of the renderer and tighten it up."].firstMatch
        let reply = window.staticTexts["Section 29: tightening the renderer"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(prompt.frame.minX, reply.frame.minX + 40)

        segment(openAppearance(app), "Plain", in: "Your Messages")

        let deadline = Date().addingTimeInterval(5)
        while prompt.frame.minX > reply.frame.minX + 40 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertLessThan(prompt.frame.minX, reply.frame.minX + 40)
    }

    /// Minimal has no + button; Inline puts it back, inside the field.
    @MainActor
    func testComposerLayouts() {
        let app = launch()
        waitForLongChat(app)
        let add = mainWindow(app).buttons["composer.add"]
        let input = mainWindow(app).descendants(matching: .any)["composer.input"]
        XCTAssertTrue(add.exists)
        let outside = input.frame.minX - add.frame.maxX

        let settings = openAppearance(app)
        segment(settings, "Minimal", in: "Layout")
        XCTAssertTrue(add.waitForNonExistence(timeout: 5))

        segment(settings, "Inline", in: "Layout")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        // Inside the field: nearer the text than the round button beside the field was.
        XCTAssertLessThan(input.frame.minX - add.frame.maxX, outside)
    }

    /// With Send With set to Command-Return, Return starts a new line and Command-Return sends.
    @MainActor
    func testCommandReturnSends() {
        let app = launch(scenario: nil)
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        choose(openAppearance(app), "Send With", "Command-Return")
        app.windows["com_apple_SwiftUI_Settings_window"].buttons[XCUIIdentifierCloseWindow].click()

        let input = mainWindow(app).descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("First line")
        input.typeKey(.return, modifierFlags: [])
        input.typeText("second line")
        XCTAssertTrue(String(describing: input.value ?? "").contains("First line\nsecond line"))
        XCTAssertFalse(app.staticTexts["Scripted response."].exists)

        input.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10))
    }

    /// Return sends by default; Shift-Return starts a new line.
    @MainActor
    func testShiftReturnStartsANewLine() {
        let app = launch(scenario: nil)
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        let input = mainWindow(app).descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("First line")
        input.typeKey(.return, modifierFlags: .shift)
        input.typeText("second line")
        XCTAssertTrue(String(describing: input.value ?? "").contains("First line\nsecond line"))

        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10))
    }

    /// Choices are kept across launches, and Restore Defaults puts them all back.
    @MainActor
    func testChoicesAreKeptAndCanBeRestored() {
        let suite = "tether.uitest.appearance.\(UUID().uuidString)"
        var app = launch(defaults: suite)
        waitForLongChat(app)
        var settings = openAppearance(app)
        segment(settings, "Compact", in: "Density")
        app.terminate()

        app = launch(defaults: suite)
        waitForLongChat(app)
        settings = openAppearance(app)
        let compact = settings.radioGroups.matching(NSPredicate(format: "label == 'Density'")).firstMatch.radioButtons["Compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue(isOn(compact))

        let restore = settings.buttons["Restore Defaults"]
        restore.scrollToVisible()
        XCTAssertTrue(restore.isEnabled)
        restore.click()
        XCTAssertFalse(isOn(compact))
        XCTAssertFalse(restore.isEnabled)
    }
}

private extension XCUIElement {
    /// Scrolls the Settings form until the element is on screen.
    func scrollToVisible() {
        var tries = 0
        while !isHittable && tries < 10 {
            let form = XCUIApplication().windows["com_apple_SwiftUI_Settings_window"].scrollViews.firstMatch
            form.scroll(byDeltaX: 0, deltaY: frame.midY > form.frame.midY ? -200 : 200)
            tries += 1
        }
    }
}
