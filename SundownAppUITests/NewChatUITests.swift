import XCTest

/// The menu bar, the toolbar's session controls, and New Chat, from the short fixture chat.
final class NewChatUITests: SundownUITestCase {
    /// Every command in the menu bar; the session controls in the toolbar, which keep their width;
    /// New Chat's chips above the composer; starting a chat; switching host.
    @MainActor
    func testNewChatAndTheSessionControls() {
        launch()
        XCTAssertTrue(text(fixtureAnswer).appears(timeout: 15), "the fixture chat never showed")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.title.contains("This Mac"), "the subtitle doesn't name the host: \(window.title)")

        // A narrow window sends toolbar items to the » menu, so the menu bar has to carry every
        // command, the Chat menu the toolbar's session controls among them.
        let expected: [String: [String]] = [
            "File": ["New Chat", "New Window", "Close"],
            "Edit": ["Find…", "Find Next", "Find Previous"],
            "View": ["Bigger", "Smaller", "Actual Size", "Chat", "Tasks", "Diff"],
            "Chat": ["Model", "Fast Mode", "Effort", "Permissions",
                     "Stop", "Open in New Window", "Pin", "Rename…", "Duplicate", "Show in Finder", "Archive", "Delete…"],
            "Help": ["Sundown Help", "Claude Code Documentation"],
        ]
        for (menu, items) in expected {
            let bar = app.menuBars.menuBarItems[menu]
            bar.click()
            for item in items {
                XCTAssertTrue(bar.descendants(matching: .menuItem)[item].exists, "\(menu) ▸ \(item)")
            }
            app.typeKey(.escape, modifierFlags: [])
        }

        // Model (with effort) is a toolbar button that opens a popover; permissions are the Chat
        // menu's, the toolbar's Permissions being hidden by default.
        let toolbar = window.toolbars.firstMatch
        let model = toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model'")).firstMatch
        XCTAssertTrue(model.appears(timeout: 5), "no Model button in the toolbar: \(toolbar.buttons.allElementsBoundByIndex.map(\.label))")

        // New Chat keeps its directory with the composer, not in a form under the toolbar: the
        // directory, the branch checked out there, and Work In, in one row above the field.
        app.typeKey("n", modifierFlags: .command)
        let folder = app.descendants(matching: .any)["newChat.folder"]
        XCTAssertTrue(folder.appears(timeout: 5), "New Chat has no directory menu")
        XCTAssertEqual(folder.value as? String, "/tmp/sundown-fixture")
        let workIn = app.descendants(matching: .any)["newChat.workIn"]
        XCTAssertTrue(workIn.exists, "New Worktree sits beside the directory")
        XCTAssertFalse(isOn(workIn), "New Worktree starts on")
        // The fixture's `git/status` says the directory is on main.
        let branch = app.descendants(matching: .any)["newChat.branch"]
        XCTAssertTrue(branch.appears(timeout: 5), "no branch beside the directory")
        XCTAssertEqual(branch.label, "Branch main")
        XCTAssertTrue(input.appears(timeout: 5))
        XCTAssertLessThan(folder.frame.maxY, input.frame.minY, "the directory isn't above the field")

        // Chat ▸ Permissions chooses the session's mode, its rows toggles checked by the one chosen.
        // From a known mode: New Chat starts in the host's (Auto in the fixture).
        func assertChosen(_ option: String) {
            app.menuBars.menuBarItems["Chat"].click()
            app.menuBars.menuItems["Permissions"].hover()
            let item = app.menuBars.menuItems[option].firstMatch
            XCTAssertTrue(item.appears(timeout: 5), "no \(option) in Chat ▸ Permissions")
            XCTAssertTrue(waitUntil(5) { (item.value as? String)?.isEmpty == false || item.isSelected },
                          "\(option) isn't checked: \(item.value ?? "nil")")
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
        }
        // Effort is a slider in the model's popover, whose value is the level's name.
        func assertEffort(_ level: String) {
            model.click()
            let slider = app.popovers.sliders.firstMatch
            XCTAssertTrue(slider.appears(timeout: 5), "no effort slider in the model popover")
            // The level's name above the slider: a slider's value reaches XCUITest as its position,
            // the name only as its value description, which XCUITest doesn't read.
            let name = app.popovers.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", level, level)).firstMatch
            XCTAssertTrue(name.appears(timeout: 5), "effort isn't \(level): \(app.popovers.staticTexts.allElementsBoundByIndex.map(\.label))")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.popovers.firstMatch.disappears(timeout: 5))
        }
        chooseMenuItem("Chat", "Ask Before Edits", in: "Permissions")
        assertChosen("Ask Before Edits")
        let before = model.frame
        // Don't Ask, not Bypass Permissions: Settings offers Bypass only when asked to.
        chooseMenuItem("Chat", "Don't Ask", in: "Permissions")
        assertChosen("Don't Ask")
        chooseMenuItem("Chat", "Max", in: "Effort")
        assertEffort("Max")
        // Within a point: AppKit rounds the toolbar's items to the pixel grid by where their symbol sits.
        XCTAssertEqual(model.frame.minX, before.minX, accuracy: 1, "Model moved")
        XCTAssertEqual(model.frame.width, before.width, accuracy: 1, "Model changed width")

        // New Worktree starts the chat in a new git worktree.
        workIn.click()
        XCTAssertTrue(waitUntil(5) { self.isOn(workIn) }, "the New Worktree switch didn't turn on")

        // The chat starts, and its reply streams in.
        send("UI test prompt")
        XCTAssertTrue(text("Scripted response.").appears(timeout: 10), "the new chat got no reply")

        // The host is switched from the menu bar only; switching opens New Chat on it, and the
        // subtitle names it.
        chooseMenuItem("Host", "Fixture SSH")
        XCTAssertTrue(waitUntil(5) { window.title.contains("Fixture SSH") }, "the title doesn't name Fixture SSH: \(window.title)")
        XCTAssertTrue(window.title.hasPrefix("New Chat"), "switching host didn't open New Chat: \(window.title)")
    }
}
