import XCTest

/// A host without the Tether server, or with one the app can't use: asked about before anything is
/// installed, installed when the user says so, and said plainly when it can't be.
final class ServerInstallUITests: XCTestCase {
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

    /// Install… asks first, showing the command; Install runs it and the chat comes up.
    @MainActor
    func testInstallingAMissingServer() {
        let app = launch(scenario: "server-missing")
        let card = statusCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.staticTexts["Tether Isn’t Installed"].waitForExistence(timeout: 5))
        card.buttons["composer.reconnect"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "install.sh | sh")).firstMatch.exists)
        sheet.buttons["Install"].click()
        XCTAssertTrue(card.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
    }

    /// Cancel installs nothing: the card still asks.
    @MainActor
    func testCancellingInstallsNothing() {
        let app = launch(scenario: "server-missing")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Tether Isn’t Installed"].waitForExistence(timeout: 15))
        card.buttons["composer.reconnect"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.staticTexts["Tether Isn’t Installed"].exists)
    }

    /// A failed install says why, and Try Again… asks again.
    @MainActor
    func testAFailedInstallSaysWhy() {
        let app = launch(scenario: "server-install-failed")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Tether Isn’t Installed"].waitForExistence(timeout: 15))
        card.buttons["composer.reconnect"].click()
        app.sheets.firstMatch.buttons["Install"].click()
        XCTAssertTrue(card.staticTexts["Couldn’t Install Tether"].waitForExistence(timeout: 15))
        XCTAssertEqual(card.buttons["composer.reconnect"].label, "Try Again…")
    }

    @MainActor
    func testAnOutdatedServerAsksForItsUpdate() {
        let app = launch(scenario: "server-outdated")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Tether Needs an Update"].waitForExistence(timeout: 15))
        XCTAssertEqual(card.buttons["composer.reconnect"].label, "Update…")
    }

    @MainActor
    func testAServerTooNewSaysTheAppIsTooOld() {
        let app = launch(scenario: "server-too-new")
        let card = statusCard(app)
        XCTAssertTrue(card.staticTexts["Couldn’t Connect"].waitForExistence(timeout: 15))
        XCTAssertTrue(card.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "needs a newer version of this app")).firstMatch.exists)
    }
}
