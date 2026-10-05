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

        // Model (with effort) and permissions are toolbar buttons that open popovers.
        let toolbar = window.toolbars.firstMatch
        let model = toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model'")).firstMatch
        let permissions = toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Permissions'")).firstMatch
        XCTAssertTrue(model.appears(timeout: 5), "no Model button in the toolbar")
        XCTAssertTrue(permissions.appears(timeout: 5), "no Permissions button in the toolbar: \(toolbar.buttons.allElementsBoundByIndex.map(\.label))")

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

        // The popovers choose the session's settings, and the permissions button says the mode in
        // its label. From a known mode: New Chat starts in the host's (Auto in the fixture).
        func chooseInPopover(_ button: XCUIElement, _ option: String) {
            button.click()
            let popover = app.popovers.firstMatch
            XCTAssertTrue(popover.appears(timeout: 5), "\(button.label) opened no popover")
            popover.settle()
            // Each row is a button naming the choice, selected when it is the chosen one.
            let item = popover.buttons.matching(NSPredicate(format: "label CONTAINS %@", option)).firstMatch
            XCTAssertTrue(item.appears(timeout: 5), "no \(option) in the popover")
            // A tall popover scrolls: the row is brought into it first.
            // Pointed at first: a popover's row takes the click only once the pointer has hovered it.
            let target = item.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            target.hover()
            Thread.sleep(forTimeInterval: 0.3)
            target.click()
            Thread.sleep(forTimeInterval: 1)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(popover.disappears(timeout: 5), "the popover stayed open after \(option)")
        }
        // The toolbar buttons' labels are their names only: the chosen row is the popover's.
        func assertChosen(_ button: XCUIElement, _ option: String) {
            button.click()
            let item = app.popovers.buttons.matching(NSPredicate(format: "label CONTAINS %@", option)).firstMatch
            XCTAssertTrue(item.appears(timeout: 5), "no \(option) in the popover")
            XCTAssertTrue(waitUntil(5) { item.isSelected }, "\(option) isn't the chosen row: \(app.popovers.buttons.allElementsBoundByIndex.map { "\($0.label)=\($0.isSelected)" })")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.popovers.firstMatch.disappears(timeout: 5))
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
        chooseInPopover(permissions, "Ask Before Edits")
        assertChosen(permissions, "Ask Before Edits")
        let before = permissions.frame
        // Don't Ask, not Bypass Permissions: Settings offers Bypass only when asked to.
        chooseInPopover(permissions, "Don't Ask")
        assertChosen(permissions, "Don't Ask")
        chooseMenuItem("Chat", "Max", in: "Effort")
        assertEffort("Max")
        // Within a point: AppKit rounds the toolbar's items to the pixel grid by where their symbol sits.
        XCTAssertEqual(permissions.frame.minX, before.minX, accuracy: 1, "Permissions moved")
        XCTAssertEqual(permissions.frame.width, before.width, accuracy: 1, "Permissions changed width")

        // New Worktree starts the chat in a new git worktree.
        workIn.click()
        XCTAssertTrue(waitUntil(5) { self.isOn(workIn) }, "the New Worktree switch didn't turn on")

        // The chat starts, and its reply streams in.
        send("UI test prompt")
        XCTAssertTrue(app.staticTexts["Scripted response."].appears(timeout: 10), "the new chat got no reply")

        // The host is switched from the menu bar only; switching opens New Chat on it, and the
        // subtitle names it.
        chooseMenuItem("Host", "Fixture SSH")
        XCTAssertTrue(waitUntil(5) { window.title.contains("Fixture SSH") }, "the title doesn't name Fixture SSH: \(window.title)")
        XCTAssertTrue(window.title.hasPrefix("New Chat"), "switching host didn't open New Chat: \(window.title)")
    }
}
