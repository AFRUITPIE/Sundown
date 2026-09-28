import XCTest

/// Settings ▸ General, Advanced and Notifications: each choice changes the chat beside it at once,
/// and is kept.
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

    /// Settings, on `pane` (General, Notifications, Hosts or Advanced).
    @MainActor
    private func openSettings(_ app: XCUIApplication, _ pane: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        let sidebar = settings.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts[pane].waitForExistence(timeout: 10))
        sidebar.staticTexts[pane].click()
        return settings
    }

    /// The control of `query`'s kind on the same row as the text `label`: a grouped form's pop-ups
    /// and switches name their row's title for VoiceOver rather than carrying it as their own label.
    @MainActor
    private func control(_ query: XCUIElementQuery, besideLabel label: String, in settings: XCUIElement) -> XCUIElement? {
        let named = query.matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
        if named.exists { return named }
        let text = settings.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", label, label)).firstMatch
        guard text.waitForExistence(timeout: 5) else { return nil }
        let row = text.frame
        for i in 0..<query.count {
            let candidate = query.element(boundBy: i)
            if abs(candidate.frame.midY - row.midY) < 14 { return candidate }
        }
        return nil
    }

    /// A toggle in Settings by its label, whichever control type it's exposed as.
    @MainActor
    private func toggle(_ settings: XCUIElement, _ label: String) -> XCUIElement {
        for query in [settings.switches, settings.checkBoxes] {
            if let match = control(query, besideLabel: label, in: settings) { return match }
        }
        return settings.switches.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? ((element.value as? String) == "1")
    }

    /// The pop-up labelled `label`.
    @MainActor
    private func popUp(_ settings: XCUIElement, _ label: String) -> XCUIElement {
        control(settings.popUpButtons, besideLabel: label, in: settings)
            ?? settings.popUpButtons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Chooses `option` from the pop-up labelled `label`.
    @MainActor
    private func choose(_ settings: XCUIElement, _ label: String, _ option: String) {
        let popUp = popUp(settings, label)
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "no \(label) pop-up")
        popUp.scrollToVisible()
        popUp.click()
        settings.menuItems[option].click()
    }

    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier != 'com_apple_SwiftUI_Settings_window'")).firstMatch
    }

    /// Advanced ▸ Tool Calls ▸ Every Call puts each finished call on a row of its own; Summarized
    /// folds runs of them again.
    @MainActor
    func testEveryCallUnfoldsFinishedCalls() {
        let app = launch()
        waitForLongChat(app)
        let groups = mainWindow(app).buttons.matching(identifier: "transcript.toolGroup")
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5))

        let settings = openSettings(app, "Advanced")
        choose(settings, "Tool Calls", "Every Call")
        XCTAssertTrue(groups.firstMatch.waitForNonExistence(timeout: 5))

        choose(settings, "Tool Calls", "Summarized")
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5))
    }

    /// With Send With set to Command-Return, Return starts a new line and Command-Return sends.
    @MainActor
    func testCommandReturnSends() {
        let app = launch(scenario: nil)
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        choose(openSettings(app, "General"), "Send With", "Command-Return")
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

    /// Advanced choices are kept across launches, and Restore Defaults puts them all back.
    @MainActor
    func testChoicesAreKeptAndCanBeRestored() {
        let suite = "tether.uitest.appearance.\(UUID().uuidString)"
        var app = launch(defaults: suite)
        waitForLongChat(app)
        choose(openSettings(app, "Advanced"), "Tool Calls", "Every Call")
        app.terminate()

        app = launch(defaults: suite)
        waitForLongChat(app)
        let settings = openSettings(app, "Advanced")
        let toolCalls = popUp(settings, "Tool Calls")
        XCTAssertTrue(toolCalls.waitForExistence(timeout: 5))
        XCTAssertEqual(toolCalls.value as? String, "Every Call")

        let restore = settings.buttons["Restore Defaults"]
        restore.scrollToVisible()
        XCTAssertTrue(restore.isEnabled)
        restore.click()
        XCTAssertEqual(toolCalls.value as? String, "Summarized")
        XCTAssertFalse(restore.isEnabled)
    }

    /// Settings ▸ Notifications has its choices, and they're kept.
    @MainActor
    func testNotificationChoicesAreKept() {
        let suite = "tether.uitest.alerts.\(UUID().uuidString)"
        var app = launch(defaults: suite)
        waitForLongChat(app)
        var settings = openSettings(app, "Notifications")
        choose(settings, "Badge Shows", "Chats Claude Is Working In")
        let sound = toggle(settings, "Play a Sound")
        XCTAssertTrue(isOn(sound))
        sound.click()
        app.terminate()

        app = launch(defaults: suite)
        waitForLongChat(app)
        settings = openSettings(app, "Notifications")
        let badge = popUp(settings, "Badge Shows")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertEqual(badge.value as? String, "Chats Claude Is Working In")
        XCTAssertFalse(isOn(toggle(settings, "Play a Sound")))
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
