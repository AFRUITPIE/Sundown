import XCTest

/// Settings' panes, each choice applying at once. That choices are kept across launches, and what
/// Restore Defaults resets, are `AppearanceTests` and `AttentionTests` in the package.
final class SettingsUITests: TetherUITestCase {
    /// General (Reading Width, Send With), Notifications, Advanced (Restore Defaults), Hosts (adding
    /// an SSH host), then Send With Command-Return in the chat.
    @MainActor
    func testSettingsPanes() {
        launch()
        XCTAssertTrue(text(fixtureAnswer).appears(timeout: 15), "the fixture chat never showed")

        // General: Reading Width, in its Chats section, and Send With.
        openSettings("General")
        XCTAssertTrue(app.staticTexts["New Chats"].appears(timeout: 10), "General has no New Chats section")
        let wide = settingsWindow.radioButtons["Wide"]
        XCTAssertTrue(wide.appears(timeout: 10), "no Reading Width")
        wide.click()
        XCTAssertEqual((wide.value as? NSNumber)?.intValue, 1, "Wide isn't chosen")
        settingsWindow.radioButtons["Narrow"].click()
        choose("Command-Return", from: "Send With")
        XCTAssertTrue(waitForValue("Command-Return", of: "Send With"), "Send With didn't take Command-Return")

        // Notifications: what the badge counts, and the sound.
        openSettings("Notifications")
        choose("Chats Claude Is Working In", from: "Badge Shows")
        XCTAssertTrue(waitForValue("Chats Claude Is Working In", of: "Badge Shows"), "Badge Shows didn't take the choice")
        let sound = toggle("Play a Sound")
        XCTAssertTrue(isOn(sound), "Play a Sound starts off")
        sound.click()
        XCTAssertFalse(isOn(sound), "Play a Sound didn't turn off")

        // Advanced: a layout chosen, and Restore Defaults putting it back.
        openSettings("Advanced")
        choose("Every Call", from: "Tool Calls")
        XCTAssertTrue(waitForValue("Every Call", of: "Tool Calls"), "Tool Calls didn't take Every Call")
        let restore = settingsWindow.buttons["Restore Defaults"]
        restore.scrollToVisible()
        XCTAssertTrue(restore.isEnabled, "Restore Defaults is disabled with a layout changed")
        restore.click()
        XCTAssertTrue(waitForValue("Summarized", of: "Tool Calls"), "Restore Defaults didn't put Tool Calls back")
        XCTAssertTrue(waitUntil(3) { !restore.isEnabled }, "Restore Defaults is still enabled")

        // Hosts: add an SSH host. Newly added hosts are deliberately denied a transport in fixture
        // mode, so it says why it can't connect.
        openSettings("Hosts")
        let addHost = app.buttons["Add SSH Host"]
        XCTAssertTrue(addHost.appears(timeout: 5), "Hosts has no Add SSH Host")
        XCTAssertTrue(app.buttons["Remove Host"].exists)
        addHost.click()
        let destination = app.textFields["host.destination"]
        XCTAssertTrue(destination.appears(timeout: 5), "Add SSH Host opened no sheet")
        destination.typeText("new-fixture.invalid")
        app.buttons["Add"].click()
        XCTAssertTrue(waitUntil(3) { self.app.buttons["Remove Host"].isEnabled }, "Remove Host is disabled with a host added")
        XCTAssertTrue(app.staticTexts["host.connectionError"].appears(timeout: 5), "the new host doesn't say why it can't connect")
        closeSettings()

        // Send With Command-Return, chosen above, applies at once: Return starts a new line and
        // Command-Return sends.
        input.click()
        input.typeText("First line")
        input.typeKey(.return, modifierFlags: [])
        input.typeText("second line")
        XCTAssertTrue(inputText().contains("First line\nsecond line"), "Return didn't start a new line: \(inputText())")
        XCTAssertFalse(app.staticTexts["Scripted response."].exists, "Return sent")
        input.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Scripted response."].appears(timeout: 10), "Command-Return didn't send")
    }

    /// Waits for the pop-up labelled `label` to show `value`, found afresh each time: the form lays
    /// its rows out again after a choice, and an element found before reads the old row.
    @MainActor
    private func waitForValue(_ value: String, of label: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if popUp(label).value as? String == value { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        print("\(label) reads \(String(describing: popUp(label).value))")
        return false
    }
}
