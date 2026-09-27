import XCTest

/// Windows, the Chat menu's actions, drafts and state restoration, against the fixture's
/// performance scenario: the fixture chat plus two more, so there is something to switch to.
final class WindowAndChatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    private func launch(defaults suite: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = "performance"
        if let suite { app.launchEnvironment["TETHER_UI_TEST_DEFAULTS"] = suite }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        XCTAssertTrue(sidebar(app).staticTexts["Performance chat 1"].waitForExistence(timeout: 20))
        return app
    }

    /// The frontmost window's sidebar, shown if AppKit restored it collapsed.
    @MainActor
    private func sidebar(_ app: XCUIApplication, in window: XCUIElement? = nil) -> XCUIElement {
        let outline = (window ?? app.windows.firstMatch).outlines["Sidebar"]
        if !outline.waitForExistence(timeout: 5) { app.menuBars.menuItems["toggleSidebar:"].click() }
        return outline
    }

    @MainActor
    private func chooseChatMenuItem(_ app: XCUIApplication, _ item: String) {
        app.menuBars.menuBarItems["Chat"].click()
        app.menuBars.menuItems[item].click()
    }

    /// The windows' titles, as the Window menu lists them (without the folder after each).
    @MainActor
    private func windowTitles(_ app: XCUIApplication) -> [String] {
        let menu = app.menuBars.menuBarItems["Window"]
        menu.click()
        let titles = menu.menuItems.matching(identifier: "makeKeyAndOrderFront:").allElementsBoundByIndex.map {
            $0.title.components(separatedBy: " (").first ?? $0.title
        }
        app.typeKey(.escape, modifierFlags: [])
        return titles
    }

    /// Waits until the Window menu lists `expected`.
    @MainActor
    private func waitForWindowTitles(_ app: XCUIApplication, _ expected: [String], timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if windowTitles(app).sorted() == expected.sorted() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        print("WINDOWS", windowTitles(app))
        return false
    }

    /// The on-screen item with this title: the menu bar lists the same commands, off screen.
    @MainActor
    private func visibleMenuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let items = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        return items.allElementsBoundByIndex.first { $0.isHittable } ?? items.firstMatch
    }

    /// The on-screen button with this title, such as an alert's: in a window or a dialog, not the
    /// Touch Bar's copy of it.
    @MainActor
    private func visibleButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let predicate = NSPredicate(format: "title == %@ OR label == %@", title, title)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for query in [app.windows.buttons.matching(predicate), app.dialogs.buttons.matching(predicate)] {
                if let button = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return button }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return app.windows.buttons.matching(predicate).firstMatch
    }

    /// A chat's row in a sidebar, by title.
    @MainActor
    private func row(_ title: String, in outline: XCUIElement) -> XCUIElement {
        outline.staticTexts[title].firstMatch
    }

    @MainActor
    func testNewWindowKeepsItsOwnChat() {
        let app = launch()
        XCTAssertTrue(waitForWindowTitles(app, ["Fixture Chat"]))

        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(waitForWindowTitles(app, ["Fixture Chat", "New Chat"]))

        // The new window is frontmost, on New Chat; choosing a chat there leaves the other window alone.
        row("Performance chat 1", in: sidebar(app)).click()
        XCTAssertTrue(waitForWindowTitles(app, ["Fixture Chat", "Performance chat 1"]))
    }

    @MainActor
    func testOpenInNewWindowFromTheChatMenu() {
        let app = launch()
        row("Performance chat 2", in: sidebar(app)).click()
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 2"]))

        chooseChatMenuItem(app, "Open in New Window")

        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 2", "Performance chat 2"]))
    }

    @MainActor
    func testDeletingAChatAsksFirst() {
        let app = launch()
        let outline = sidebar(app)
        let chat = row("Performance chat 2", in: outline)
        chat.rightClick()
        visibleMenuItem(app, "Delete…").click()
        XCTAssertTrue(app.staticTexts["Delete “Performance chat 2”?"].waitForExistence(timeout: 5))
        visibleButton(app, "Cancel").click()
        XCTAssertTrue(chat.exists, "Cancel keeps the chat")

        chat.rightClick()
        visibleMenuItem(app, "Delete…").click()
        visibleButton(app, "Delete").click()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testRenamingFromTheChatMenu() {
        let app = launch()
        let outline = sidebar(app)
        row("Performance chat 1", in: outline).click()

        chooseChatMenuItem(app, "Rename…")
        // The alert opens with the current title, ready to replace.
        let field = app.sheets.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Performance chat 1")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed Chat")
        visibleButton(app, "Rename").click()

        XCTAssertTrue(row("Renamed Chat", in: outline).waitForExistence(timeout: 5))
        XCTAssertFalse(row("Performance chat 1", in: outline).exists)
    }

    @MainActor
    func testDuplicateOpensTheCopy() {
        let app = launch()
        let outline = sidebar(app)
        let before = outline.staticTexts.matching(identifier: "Performance chat 1").count
        row("Performance chat 1", in: outline).rightClick()
        visibleMenuItem(app, "Duplicate").click()

        let copies = outline.staticTexts.matching(identifier: "Performance chat 1")
        let deadline = Date().addingTimeInterval(5)
        while copies.count == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(copies.count, before + 1)
    }

    @MainActor
    func testADraftSurvivesSwitchingChats() {
        let app = launch()
        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("half a thought")

        row("Performance chat 1", in: sidebar(app)).click()
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 1"]))
        XCTAssertFalse(String(describing: input.value ?? "").contains("half a thought"))

        row("Fixture Chat", in: sidebar(app)).click()
        XCTAssertTrue(waitForWindowTitles(app, ["Fixture Chat"]))
        XCTAssertTrue(String(describing: input.value ?? "").contains("half a thought"))
    }

    @MainActor
    func testTheLastChatReopensAfterRelaunch() {
        let suite = "tether.uitest.relaunch.\(UUID().uuidString)"
        var app = launch(defaults: suite)
        row("Performance chat 2", in: sidebar(app)).click()
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 2"]))
        app.terminate()

        app = launch(defaults: suite)
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 2"], timeout: 10))
    }

    /// A group of finished calls opens from its disclosure triangle and shows each call.
    @MainActor
    func testToolGroupsOpenToShowTheirCalls() {
        let app = launch()
        let groups = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Used '"))
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 10))
        // One on screen: the chat opens at its end, and the first groups are far above.
        guard let group = groups.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no tool group on screen")
        }
        let count = Int(group.label.split(separator: " ")[1]) ?? 0
        let buttons = app.buttons.count

        group.click()

        // Each call in the group is a row of its own now.
        let deadline = Date().addingTimeInterval(5)
        while app.buttons.count < buttons + count && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(app.buttons.count, buttons + count)
    }

    /// ⌃⇥ and ⌃⇧⇥ step through the sidebar's chats.
    @MainActor
    func testControlTabStepsThroughChats() {
        let app = launch()
        row("Performance chat 1", in: sidebar(app)).click()
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 1"]))

        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 2"]))
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForWindowTitles(app, ["Performance chat 1"]))
    }

    /// ⇧⌘M steps the permission mode, as Shift-Tab does in the CLI. On New Chat, where the
    /// mode is the draft's and changes without a round trip to the fixture.
    @MainActor
    func testShiftCommandMStepsThePermissionMode() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForWindowTitles(app, ["New Chat"]))
        let permissions = app.windows.firstMatch.toolbars.menuButtons["Permissions"]
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        let before = permissions.value as? String

        app.typeKey("m", modifierFlags: [.command, .shift])

        let deadline = Date().addingTimeInterval(5)
        while permissions.value as? String == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertNotEqual(permissions.value as? String, before)
    }

    /// Archive takes a chat out of the list without deleting it; Show ▸ Archived lists it again.
    @MainActor
    func testArchivingHidesAChatUntilShown() {
        let app = launch()
        let outline = sidebar(app)
        let chat = row("Performance chat 2", in: outline)
        chat.rightClick()
        visibleMenuItem(app, "Archive").click()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 5))

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Show"].hover()
        app.menuBars.menuItems["Archived"].click()
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        XCTAssertFalse(row("Performance chat 1", in: outline).exists)

        chat.rightClick()
        visibleMenuItem(app, "Unarchive").click()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 5))
    }
}
