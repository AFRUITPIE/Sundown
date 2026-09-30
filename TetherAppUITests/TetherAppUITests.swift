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

    /// The inspector opens from its toolbar button, and its tabs, SwiftUI's own over the pane,
    /// switch panes.
    @MainActor
    func testExistingChatAndInspector() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let toggle = app.buttons["Inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // The fixture's store is fresh, so the inspector starts closed, with no tabs.
        let mcp = paneTab(app, "MCP")
        XCTAssertFalse(mcp.exists)
        toggle.click()
        XCTAssertTrue(mcp.waitForExistence(timeout: 5))
        mcp.click()
        let empty = app.staticTexts["No MCP Servers"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual((mcp.value as? NSNumber)?.intValue, 1)
        XCTAssertEqual((paneTab(app, "Tasks").value as? NSNumber)?.intValue, 0)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(empty.waitForNonExistence(timeout: 5))
    }

    /// One of the inspector's tabs: a tab, or a radio button, however the tab bar reports it; not
    /// View ▸ Inspector's menu item of the same name.
    @MainActor
    private func paneTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.tab.rawValue, XCUIElement.ElementType.radioButton.rawValue]
        return app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", name, types))
            .element(boundBy: 0)
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
        // Each says its choice after its name ("Permissions, Don't Ask").
        let effort = toolbar.menuButtons.matching(NSPredicate(format: "label BEGINSWITH 'Effort'")).firstMatch
        let permissions = toolbar.menuButtons.matching(NSPredicate(format: "label BEGINSWITH 'Permissions'")).firstMatch
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        let before = (effort.frame, permissions.frame)

        // Don't Ask, not Bypass Permissions: Settings offers Bypass only when asked to.
        choose("Don't Ask", in: "Permissions", app: app)
        choose("Max", in: "Effort", app: app)

        XCTAssertEqual(permissions.label, "Permissions, Don't Ask")
        // Each control holds its width within a point: AppKit rounds each segment of the toolbar's
        // control group to the pixel grid by where its visible symbol sits, though the label
        // reserves the same width for all. Where one sits can drift by that rounding of each of the
        // group's three segments (New Chat starts in the host's mode, Auto here, then Don't Ask).
        for (after, was) in [(effort.frame, before.0), (permissions.frame, before.1)] {
            XCTAssertEqual(after.minX, was.minX, accuracy: 3)
            XCTAssertEqual(after.width, was.width, accuracy: 1)
        }
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

    /// New Chat keeps its folder with the composer, not in a form under the toolbar: the folder,
    /// the branch checked out there, and Work In, in one row above the field.
    @MainActor
    func testNewChatFolderSitsAboveTheComposer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Fixture Chat"].waitForExistence(timeout: 15))
        app.buttons["New Chat"].click()
        let folder = app.descendants(matching: .any)["newChat.folder"]
        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        let workIn = app.descendants(matching: .any)["newChat.workIn"]
        XCTAssertTrue(workIn.exists, "Work In sits beside the folder")
        XCTAssertEqual(workIn.value as? String, "This Directory")
        // The fixture's `git/status` says the folder is on main.
        let branch = app.descendants(matching: .any)["newChat.branch"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        XCTAssertEqual(branch.label, "Branch main")
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
        // Sending must finish: the new message's actions become usable after the spring settles.
        let copy = app.buttons["message.copy.fixture-sent-1"]
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 5), .completed)
    }

    /// Sending from the end of a full transcript makes room and leaves the new prompt usable.
    @MainActor
    func testSendingLiftsTheTranscript() {
        let app = launch(scenario: "performance")
        defer { app.terminate() }
        let previous = app.staticTexts["Section 29: tightening the renderer"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 20))
        let before = previous.frame.minY
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Follow up")
        app.buttons["composer.send"].click()
        let copy = app.buttons["message.copy.perf-sent-1"]
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 8), .completed)
        XCTAssertLessThan(previous.frame.minY, before - 20)
        XCTAssertLessThan(copy.frame.maxY, input.frame.minY)
    }

    /// A wrapped prompt keeps its final text layout while its native glass surface travels.
    @MainActor
    func testLongPromptStaysReadableAfterSending() {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture answer from the local transport."].waitForExistence(timeout: 15))
        let prompt = Array(repeating: "Keep this longer message readable as it lifts from the composer, wraps across several lines, and settles into the transcript.", count: 4).joined(separator: " ")
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText(prompt)
        app.buttons["composer.send"].click()
        XCTAssertTrue(app.staticTexts["Scripted response."].waitForExistence(timeout: 10))
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", prompt, prompt)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(message.frame.height, 40)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(message.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(message.frame.maxX, window.maxX)
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
        // Reading Width, in General's Chats section.
        XCTAssertTrue(app.radioButtons["Wide"].waitForExistence(timeout: 10))
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
        // Several pages back: each turn is about twenty items, a page fifty. The earliest section on
        // screen, since a scroll can carry the reader past any one of them as pages go in above.
        func earliestSection() -> Int? {
            app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Section '")).allElementsBoundByIndex.compactMap { text in
                (text.value as? String)?.dropFirst("Section ".count).split(separator: ":").first.flatMap { Int($0) }
            }.min()
        }
        // A point in the transcript: a heading leaves the lazy stack once it scrolls away.
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<30 where (earliestSection() ?? .max) > 12 {
            transcript.scroll(byDeltaX: 0, deltaY: 4000)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertLessThanOrEqual(earliestSection() ?? .max, 12)
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

    /// Opening and closing the inspector in a window as narrow as it goes. The detail column's
    /// minimum used to come from whatever its content measured, and with the composer's + button
    /// that made AppKit lay the window out again and again until it gave up and crashed.
    @MainActor
    func testInspectorInANarrowWindow() {
        let app = launch(scenario: "performance")
        XCTAssertTrue(app.staticTexts["Section 29: tightening the renderer"].firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        // As narrow as the window allows: the drag goes further than the minimum.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -600, dy: 0)),
                     withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.1)

        for _ in 0..<3 {
            app.typeKey("i", modifierFlags: [.command, .option])
            Thread.sleep(forTimeInterval: 1)
            app.typeKey("i", modifierFlags: [.command, .option])
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(window.exists)
    }
}
