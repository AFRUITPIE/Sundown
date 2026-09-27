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
        // The windows a debug run left open (or none, if it was stopped) are not restored.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if let scenario { app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario }
        app.launch()
        return app
    }

    /// The inspector opens from its toolbar button, and its tabs switch panes.
    @MainActor
    func testExistingChatAndInspector() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let toggle = app.buttons["Inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // The fixture's store is fresh, so the inspector starts closed.
        toggle.click()
        let mcp = app.tabGroups["Inspector"].tabs["MCP"]
        XCTAssertTrue(mcp.waitForExistence(timeout: 5))
        // With the inspector open the window's minimum width reaches past the CI runner's display
        // (#38), where the tab and the toggle aren't hittable, so both go by shortcut from here.
        app.typeKey("3", modifierFlags: [.command, .option])
        let empty = app.staticTexts["No MCP Servers"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual((mcp.value as? NSNumber)?.intValue, 1)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(empty.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testInspectorPaneShortcuts() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        // ⌥⌘3 opens the inspector on MCP; ⌥⌘I hides it and reopens it on the same pane.
        app.typeKey("3", modifierFlags: [.command, .option])
        let empty = app.staticTexts["No MCP Servers"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(empty.waitForNonExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
    }

    /// The host is switched from the menu bar only, and the subtitle then names it.
    @MainActor
    func testHostMenuSwitchesHost() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.title.contains("This Mac"), window.title)
        app.menuBars.menuBarItems["Host"].click()
        app.menuBars.menuItems["Fixture SSH"].click()
        let switched = NSPredicate(format: "title CONTAINS %@", "Fixture SSH")
        expectation(for: switched, evaluatedWith: window)
        waitForExpectations(timeout: 5)
        // Switching host opens New Chat on it.
        XCTAssertTrue(window.title.hasPrefix("New Chat"), window.title)
    }

    /// Choosing another value never resizes a session control or moves its neighbours.
    @MainActor
    func testSessionControlsKeepTheirWidth() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture Chat"].waitForExistence(timeout: 15))
        app.buttons["New Chat"].click()
        let toolbar = app.toolbars.firstMatch
        let effort = toolbar.menuButtons["Effort"]
        let permissions = toolbar.menuButtons["Permissions"]
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        let before = (effort.frame, permissions.frame)

        choose("Bypass Permissions", in: "Permissions", app: app)
        choose("Max", in: "Effort", app: app)

        XCTAssertEqual(permissions.value as? String, "Bypass Permissions")
        XCTAssertEqual(effort.frame, before.0)
        XCTAssertEqual(permissions.frame, before.1)
    }

    /// Every toolbar control is also in the menu bar.
    @MainActor
    func testChatMenuRepeatsTheSessionControls() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture Chat"].waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Chat"].click()
        for title in ["Model", "Fast Mode", "Effort", "Permissions"] {
            XCTAssertTrue(app.menuBars.menuItems[title].exists, title)
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    /// New Chat keeps its folder with the composer, not in a form under the toolbar.
    @MainActor
    func testNewChatFolderSitsAboveTheComposer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture Chat"].waitForExistence(timeout: 15))
        app.buttons["New Chat"].click()
        let folder = app.popUpButtons["newChat.folder"]
        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertLessThan(folder.frame.maxY, input.frame.minY)
        XCTAssertEqual(folder.value as? String, "/tmp/tether-fixture")
    }

    @MainActor
    private func choose(_ item: String, in submenu: String, app: XCUIApplication) {
        app.menuBars.menuBarItems["Chat"].click()
        app.menuBars.menuItems[submenu].hover()
        app.menuBars.menuItems[item].click()
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
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        // AppKit keeps the sidebar's collapsed state in the app's own defaults, which a debug run
        // shares. Checked by the list itself: the menu item's title can lag the sidebar's state.
        if !app.outlines["Sidebar"].exists { app.menuBars.menuItems["toggleSidebar:"].click() }
        let row = app.outlines["Sidebar"].staticTexts["Fixture Chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let search = app.windows.firstMatch.searchFields.firstMatch
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

    /// A chat opens with its latest page; each time the reader reaches the top, the page before it
    /// loads above them, page after page. It used to stop after one or two.
    @MainActor
    func testScrollingUpLoadsOlderMessages() {
        let app = launch(scenario: "performance")
        XCTAssertTrue(app.staticTexts["Section 29: tightening the renderer"].firstMatch.waitForExistence(timeout: 20))
        // Several pages back: each turn is about twenty items, a page fifty.
        let older = app.staticTexts["Section 12: tightening the renderer"].firstMatch
        // A point in the transcript: a heading leaves the lazy stack once it scrolls away.
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<30 where !older.exists {
            transcript.scroll(byDeltaX: 0, deltaY: 4000)
            _ = older.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(older.exists)
    }

    /// The jump button is offered once the reader scrolls away from the end, and takes them back.
    @MainActor
    func testJumpToLatestAfterScrollingUp() {
        let app = launch(scenario: "performance")
        let latest = app.staticTexts["Section 29: tightening the renderer"].firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 20))
        let jump = app.buttons["Jump to Latest"]
        XCTAssertFalse(jump.exists)
        latest.scroll(byDeltaX: 0, deltaY: 3000)
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.click()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        XCTAssertTrue(latest.isHittable)
    }
}
