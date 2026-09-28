import XCTest

/// The layouts Settings ▸ Advanced compares, each switched live with a chat open (switching is where
/// a layout loop would show), and the transcript's newer rows: Worked For, edited files, dates,
/// the status card, prompt navigation, pins and Work In.
final class LayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    /// The app on a fixture scenario, starting from `appearance` (the JSON Settings stores).
    @MainActor
    private func launch(scenario: String? = "performance", appearance: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        if let scenario { app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario }
        if let appearance { app.launchEnvironment["TETHER_UI_TEST_APPEARANCE"] = appearance }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        return app
    }

    /// The static text that says `text`. Not `firstMatch`: once the Chat tab is shown again, its
    /// shortcut through the tree misses elements a whole query finds.
    @MainActor
    private func text(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", text, text)).element(boundBy: 0)
    }

    @MainActor
    private func waitForLongChat(_ app: XCUIApplication) {
        XCTAssertTrue(text(app, "Section 29: tightening the renderer").waitForExistence(timeout: 20))
    }

    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'SwiftUI.WindowGroup'")).element(boundBy: 0)
    }

    // MARK: Settings

    @MainActor
    private func openAdvanced(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        let sidebar = settings.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts["Advanced"].waitForExistence(timeout: 10))
        sidebar.staticTexts["Advanced"].click()
        return settings
    }

    /// Chooses `option` from the Settings pop-up on the row titled `label`.
    @MainActor
    private func choose(_ settings: XCUIElement, _ label: String, _ option: String) {
        let text = settings.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", label, label)).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "no \(label) row")
        let popUps = settings.popUpButtons
        let popUp = (0..<popUps.count).map { popUps.element(boundBy: $0) }
            .first { abs($0.frame.midY - text.frame.midY) < 14 }
        guard let popUp else { return XCTFail("no \(label) pop-up") }
        popUp.click()
        settings.menuItems[option].click()
    }

    /// Closes Settings and brings the chat window back to the front.
    @MainActor
    private func closeSettings(_ app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        mainWindow(app).click()
    }

    // MARK: Panes

    /// Every placement opens the MCP pane (⌥⌘3) and closes it again (⌥⌘I), switched while the chat
    /// is open. Outside the columns, opening it never changes the chat window's width.
    @MainActor
    func testEveryPanePlacementShowsThePanes() {
        let app = launch()
        waitForLongChat(app)
        let empty = text(app, "No MCP Servers")
        for placement in ["Tabs", "Floating Panel", "Drawer", "Card Over the Chat", "System Inspector", "Inspector"] {
            let settings = openAdvanced(app)
            choose(settings, "Show Panes In", placement)
            closeSettings(app)
            let width = mainWindow(app).frame.width

            app.typeKey("3", modifierFlags: [.command, .option])
            XCTAssertTrue(empty.waitForExistence(timeout: 5), "\(placement): no MCP pane")
            if !placement.hasSuffix("Inspector") {
                XCTAssertEqual(mainWindow(app).frame.width, width, accuracy: 1, "\(placement) changed the window's width")
            }
            if placement == "Floating Panel" {
                XCTAssertTrue(app.windows["Inspector"].exists || app.dialogs["Inspector"].exists, "no floating panel")
            }
            // Tabs shows the chat again from its Chat tab; the others hide the panes.
            if placement == "Tabs" {
                app.typeKey("i", modifierFlags: [.command, .option])
                waitForLongChat(app)
            } else {
                mainWindow(app).click()
                app.typeKey("i", modifierFlags: [.command, .option])
                XCTAssertTrue(empty.waitForNonExistence(timeout: 5), "\(placement): the panes stayed")
            }
        }
    }

    /// Tabs puts the chat and each pane in the toolbar as tabs; ⌥⌘I goes back to the chat.
    @MainActor
    func testTabsAreInTheToolbar() {
        let app = launch(appearance: #"{"inspector":"tabs"}"#)
        waitForLongChat(app)
        let tabs = mainWindow(app).toolbars.element(boundBy: 0).tabGroups.element(boundBy: 0)
        let changes = tabs.tabs["Changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.tabs.count, 5)
        changes.click()
        XCTAssertTrue(text(app, "App.swift").waitForExistence(timeout: 5))
        tabs.tabs["Chat"].click()
        waitForLongChat(app)

        app.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(text(app, "No MCP Servers").waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.tabs["MCP"].value as? Int, 1)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(text(app, "No MCP Servers").waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabs.tabs["Chat"].value as? Int, 1)
        waitForLongChat(app)
    }

    // MARK: Session controls

    /// Session Controls moves the model, effort and permissions menus between the toolbar and the
    /// message field, and Split leaves permissions in the toolbar.
    @MainActor
    func testSessionControlsMoveBetweenToolbarAndField() {
        let app = launch()
        waitForLongChat(app)
        let window = mainWindow(app)
        let toolbarModel = window.toolbars.menuButtons["Model"]
        XCTAssertTrue(toolbarModel.waitForExistence(timeout: 5))

        var settings = openAdvanced(app)
        choose(settings, "Session Controls", "Message Field")
        closeSettings(app)
        XCTAssertTrue(toolbarModel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.menuButtons.matching(identifier: "composer.model").firstMatch.exists
                      || window.menuButtons["Model"].exists, "no Model menu in the field")

        settings = openAdvanced(app)
        choose(settings, "Session Controls", "Split")
        closeSettings(app)
        XCTAssertTrue(window.toolbars.menuButtons["Permissions"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.toolbars.menuButtons["Model"].exists)

        settings = openAdvanced(app)
        choose(settings, "Session Controls", "Toolbar")
        closeSettings(app)
        XCTAssertTrue(toolbarModel.waitForExistence(timeout: 5))
    }

    // MARK: Transcript

    /// Worked For folds each finished turn's work behind one line, which opens to show it.
    @MainActor
    func testWorkedForFoldsFinishedTurns() {
        let app = launch(appearance: #"{"toolCalls":"workedFor"}"#)
        waitForLongChat(app)
        let folds = app.buttons.matching(identifier: "transcript.turnWork")
        XCTAssertTrue(folds.firstMatch.waitForExistence(timeout: 5))
        guard let fold = folds.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no Worked For line on screen")
        }
        XCTAssertTrue(fold.label.hasPrefix("Worked"))
        let calls = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["transcript.toolCall", "transcript.toolGroup"]))
        let before = calls.count
        fold.click()
        let deadline = Date().addingTimeInterval(5)
        while calls.count <= before && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(calls.count, before)
    }

    /// A turn that edited files ends with a row that lists them; a file opens to its diff.
    @MainActor
    func testEditedFilesRowListsTheTurnsFiles() {
        let app = launch()
        waitForLongChat(app)
        let rows = app.buttons.matching(identifier: "transcript.edits")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        guard let row = rows.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no edited-files row on screen")
        }
        XCTAssertTrue(row.label.hasPrefix("Edited"))
        row.click()
        let file = app.buttons.matching(identifier: "transcript.editedFile").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restore Files…"].exists)
    }

    /// Prompts are dated, as in Messages.
    @MainActor
    func testPromptsAreDated() {
        let app = launch()
        waitForLongChat(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "transcript.date").firstMatch.exists)
    }

    /// Chat ▸ Previous Prompt (⌥⌘↑) brings the prompt above the reader's place to the top, one at a
    /// time, pressed slowly or in quick succession, and on past the page loaded when the chat opened.
    @MainActor
    func testPreviousPromptGoesBackOneAtATime() {
        let app = launch()
        waitForLongChat(app)
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        guard let first = topPrompt(app) else { return XCTFail("no prompt at the top") }
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        XCTAssertEqual(topPrompt(app), first - 1)
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        XCTAssertEqual(topPrompt(app), first - 3)
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        XCTAssertEqual(topPrompt(app), first - 2)
    }

    /// The number of the "Step n" prompt nearest the top of the transcript, once scrolling settles.
    @MainActor
    private func topPrompt(_ app: XCUIApplication) -> Int? {
        // The widest scroll view: the sidebar's is narrower.
        guard let transcript = mainWindow(app).scrollViews.allElementsBoundByIndex
            .max(by: { $0.frame.width < $1.frame.width }) else { return nil }
        let prompts = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Step '"))
        var last: Int?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            let top = transcript.frame.minY
            let number = prompts.allElementsBoundByIndex
                .filter { $0.frame.minY >= top - 2 }
                .min { $0.frame.minY < $1.frame.minY }
                .flatMap { ($0.value as? String)?.dropFirst(5).prefix { $0.isNumber } }
                .flatMap { Int($0) }
            if number != nil, number == last { return number }
            last = number
        }
        return last
    }

    /// While the host can't be reached, a card takes the message field's place with Reconnect on it.
    @MainActor
    func testTheStatusCardOffersReconnect() {
        let app = launch(scenario: "connect-failure")
        let card = app.descendants(matching: .any).matching(identifier: "composer.status").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        // The fixture fails twice, retrying on its own in between, so the card says so for a few
        // seconds with Reconnect on it.
        XCTAssertTrue(card.staticTexts["Couldn’t Connect"].waitForExistence(timeout: 5))
        let reconnect = card.buttons["composer.reconnect"]
        XCTAssertTrue(reconnect.exists)
        reconnect.click()
        XCTAssertTrue(card.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["composer.input"].exists)
    }

    // MARK: Sidebar and New Chat

    /// Chat ▸ Pin puts the chat in Pinned at the top of the sidebar; Unpin takes it out.
    @MainActor
    func testPinningAChat() {
        let app = launch()
        waitForLongChat(app)
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertFalse(sidebar.staticTexts["Pinned"].exists)
        app.typeKey("p", modifierFlags: [.command, .option])
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))
        app.typeKey("p", modifierFlags: [.command, .option])
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForNonExistence(timeout: 5))
    }

    /// Settings ▸ Advanced ▸ Sidebar ▸ Activity lists the chats by day, switched live.
    @MainActor
    func testActivitySidebar() {
        let app = launch()
        waitForLongChat(app)
        let settings = openAdvanced(app)
        choose(settings, "Layout", "Activity")
        closeSettings(app)
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts["Performance chat 2"].waitForExistence(timeout: 5))
    }

    /// New Chat's Work In menu starts the chat in a new worktree.
    @MainActor
    func testWorkInChoosesAWorktree() {
        let app = launch(scenario: nil)
        XCTAssertTrue(app.staticTexts["Fixture Chat"].waitForExistence(timeout: 15))
        app.buttons["New Chat"].click()
        let workIn = app.descendants(matching: .any)["newChat.workIn"]
        XCTAssertTrue(workIn.waitForExistence(timeout: 5))
        XCTAssertEqual(workIn.value as? String, "This Folder")
        workIn.click()
        app.menuItems["New Worktree"].click()
        XCTAssertEqual(workIn.value as? String, "New Worktree")
    }
}
