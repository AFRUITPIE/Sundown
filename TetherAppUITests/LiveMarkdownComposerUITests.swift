import XCTest

/// The message field with Settings ▸ Advanced ▸ Composer ▸ Live Markdown: Markdown styled as it's
/// typed, sent exactly as typed, with Return and Shift-Return as in the plain field.
final class LiveMarkdownComposerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    private func launch(live: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        if live { app.launchEnvironment["TETHER_UI_TEST_APPEARANCE"] = #"{"composer":"liveMarkdown"}"# }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    /// The field's text, for its value; it's clicked by the scroll view around it, which is only as
    /// tall as the text shows, where the text view itself runs taller.
    @MainActor
    private func input(_ app: XCUIApplication) -> XCUIElement {
        let field = app.windows.firstMatch.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Where the field shows, which is where a person clicks: XCTest finds no free point on either.
        let visible = app.windows.firstMatch.scrollViews.containing(.any, identifier: "composer.input").firstMatch
        visible.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        return field
    }

    /// Shift-Return starts a line, Return sends, and the Markdown goes as typed.
    @MainActor
    func testShiftReturnStartsALineAndReturnSends() {
        let app = launch()
        let field = input(app)
        app.typeText("Look at **the bar**")
        app.typeKey(.return, modifierFlags: .shift)
        app.typeText("and `code`")
        XCTAssertTrue(String(describing: field.value ?? "").contains("Look at **the bar**\nand `code`"))
        XCTAssertFalse(app.staticTexts["Scripted response."].exists)

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10))
        // Sent, the field is empty again.
        XCTAssertFalse(String(describing: field.value ?? "").contains("Look at"))
    }
}
