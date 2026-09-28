import XCTest

/// A host without Node.js 18 or later: said plainly, with Check Again, and Tether installed there
/// only when the user says so.
final class ServerSetupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        return app
    }

    @MainActor
    private func statusCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer.status").firstMatch
    }

    /// Install Tether puts the server there, and the chat comes up.
    @MainActor
    func testInstallingTetherOnAHostWithoutNode() {
        let app = launch(scenario: "node-missing")
        let card = statusCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.staticTexts["Tether Needs Node.js"].waitForExistence(timeout: 5))
        XCTAssertEqual(card.buttons["composer.reconnect"].label, "Check Again")
        XCTAssertEqual(card.buttons["composer.installServer"].label, "Install Tether")
        card.buttons["composer.installServer"].click()
        XCTAssertTrue(card.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
    }

    /// Check Again looks again, and still says what's needed.
    @MainActor
    func testCheckingAgainStillAsks() {
        let app = launch(scenario: "node-missing")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Tether Needs Node.js"].waitForExistence(timeout: 15))
        card.buttons["composer.reconnect"].click()
        XCTAssertTrue(card.staticTexts["Tether Needs Node.js"].waitForExistence(timeout: 15))
    }

    /// A failed install says why, with Try Again.
    @MainActor
    func testAFailedInstallSaysWhy() {
        let app = launch(scenario: "copy-failed")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Tether Needs Node.js"].waitForExistence(timeout: 15))
        card.buttons["composer.installServer"].click()
        XCTAssertTrue(card.staticTexts["Couldn’t Install Tether"].waitForExistence(timeout: 15))
        XCTAssertEqual(card.buttons["composer.installServer"].label, "Try Again")
    }

    @MainActor
    func testAnOldNodeIsNamed() {
        let app = launch(scenario: "node-outdated")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Tether Needs Node.js"].waitForExistence(timeout: 15))
        XCTAssertTrue(card.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "has Node.js 16.20.2")).firstMatch.exists)
    }
}
