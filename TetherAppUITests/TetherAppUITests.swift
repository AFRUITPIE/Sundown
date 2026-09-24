import XCTest

/// Runs the real macOS app against an in-process JSON-RPC fixture. Every launch sets the
/// fixture flag; HostConnection then rejects any attempt to start a daemon or SSH process.
final class TetherAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(scenario: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        if let scenario { app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario }
        app.launch()
        return app
    }

    @MainActor
    func testExistingChatAndInspector() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["No Tasks"].waitForExistence(timeout: 5))
        let session = app.descendants(matching: .any)["inspector.session"]
        XCTAssertTrue(session.exists)
        session.click()
        XCTAssertTrue(app.staticTexts["Context"].waitForExistence(timeout: 5))
        session.click()
        XCTAssertFalse(app.staticTexts["Context"].exists)
        app.descendants(matching: .any)["inspector.mcp"].click()
        XCTAssertTrue(app.staticTexts["No MCP Servers"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testExistingChatAcceptsScriptedTurn() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Follow up")
        app.buttons["composer.send"].click()
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSidebarSearch() {
        let app = launch()
        let row = app.outlines["Sidebar"].staticTexts["Fixture Chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("no matching fixture")
        XCTAssertFalse(row.exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Fixture")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSidebarAndHostManagement() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let sidebar = app.windows["com_apple_SwiftUI_Settings_window"].outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts["General"].waitForExistence(timeout: 10))
        sidebar.staticTexts["General"].click()
        XCTAssertTrue(app.staticTexts["New Chats"].waitForExistence(timeout: 10))
        app.radioButtons["Wide"].click()
        XCTAssertEqual((app.radioButtons["Wide"].value as? NSNumber)?.intValue, 1)
        app.radioButtons["Narrow"].click()
        sidebar.staticTexts["Hosts"].click()
        XCTAssertTrue(app.buttons["Add SSH Host"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove Host"].exists)

        app.buttons["Add SSH Host"].click()
        let destination = app.textFields["host.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.typeText("new-fixture.invalid")
        app.buttons["Add"].click()
        XCTAssertTrue(app.buttons["Remove Host"].isEnabled)
        // Newly added hosts are deliberately denied a transport in fixture mode.
        let error = app.staticTexts["host.connectionError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNewChatStreamsScriptedResponse() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture Chat"].waitForExistence(timeout: 15))
        app.buttons["New Chat"].click()
        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("UI test prompt")
        app.buttons["composer.send"].click()
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10))
    }

    @MainActor
    func testConnectionFailureRecovers() {
        let app = launch(scenario: "connect-failure")
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
    }

    @MainActor
    func testPermissionPromptKeepsComposerDraft() {
        let app = launch(scenario: "permission")
        XCTAssertTrue(app.staticTexts["Allow fixture command?"].waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Draft survives permission")
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        app.buttons["Deny…"].click()
        app.buttons["Deny"].click()
        XCTAssertFalse(app.staticTexts["Allow fixture command?"].exists)
        XCTAssertTrue(String(describing: input.value ?? "").contains("Draft survives permission"))
    }
}
