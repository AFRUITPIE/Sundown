import XCTest

/// The menu bar, the toolbar's session controls, and New Chat, from the short fixture chat.
final class NewChatUITests: TetherUITestCase {
    /// Every command in the menu bar; the session controls in the toolbar, which keep their width;
    /// New Chat's row above the composer and Work In; starting a chat; switching host.
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
            "View": ["Bigger", "Smaller", "Actual Size", "Show Inspector"],
            "Chat": ["Model", "Fast Mode", "Effort", "Permissions",
                     "Stop", "Open in New Window", "Pin", "Rename…", "Duplicate", "Show in Finder", "Archive", "Delete…"],
            "Help": ["Tether Help", "Claude Code Documentation"],
        ]
        for (menu, items) in expected {
            let bar = app.menuBars.menuBarItems[menu]
            bar.click()
            for item in items {
                XCTAssertTrue(bar.descendants(matching: .menuItem)[item].exists, "\(menu) ▸ \(item)")
            }
            app.typeKey(.escape, modifierFlags: [])
        }

        // Model, effort and permissions share one toolbar item.
        let toolbar = window.toolbars.firstMatch
        for menu in ["Model", "Effort", "Permissions"] {
            let button = toolbar.menuButtons.matching(NSPredicate(format: "label BEGINSWITH %@", menu)).firstMatch
            XCTAssertTrue(button.appears(timeout: 5), "no \(menu) menu in the toolbar")
        }

        // New Chat keeps its directory with the composer, not in a form under the toolbar: the
        // directory, the branch checked out there, and Work In, in one row above the field.
        app.buttons["New Chat"].click()
        let folder = app.descendants(matching: .any)["newChat.folder"]
        XCTAssertTrue(folder.appears(timeout: 5), "New Chat has no directory menu")
        XCTAssertEqual(folder.value as? String, "/tmp/tether-fixture")
        let workIn = app.descendants(matching: .any)["newChat.workIn"]
        XCTAssertTrue(workIn.exists, "Work In sits beside the directory")
        XCTAssertEqual(workIn.value as? String, "This Directory")
        // The fixture's `git/status` says the directory is on main.
        let branch = app.descendants(matching: .any)["newChat.branch"]
        XCTAssertTrue(branch.appears(timeout: 5), "no branch beside the directory")
        XCTAssertEqual(branch.label, "Branch main")
        XCTAssertTrue(input.appears(timeout: 5))
        XCTAssertLessThan(folder.frame.maxY, input.frame.minY, "the directory isn't above the field")

        // Choosing another value never resizes a session control or moves its neighbours. Each
        // says its choice after its name ("Permissions, Don't Ask").
        let effort = toolbar.menuButtons.matching(NSPredicate(format: "label BEGINSWITH 'Effort'")).firstMatch
        let permissions = toolbar.menuButtons.matching(NSPredicate(format: "label BEGINSWITH 'Permissions'")).firstMatch
        XCTAssertTrue(permissions.appears(timeout: 5))
        // From a known mode: New Chat starts in the host's (Auto in the fixture), whose symbol
        // AppKit measures wider than the others.
        chooseMenuItem("Chat", "Ask Before Edits", in: "Permissions")
        let before = (effort.frame, permissions.frame)
        // Don't Ask, not Bypass Permissions: Settings offers Bypass only when asked to.
        chooseMenuItem("Chat", "Don't Ask", in: "Permissions")
        chooseMenuItem("Chat", "Max", in: "Effort")
        XCTAssertEqual(permissions.label, "Permissions, Don't Ask")
        // Within a point: AppKit rounds each segment of the toolbar's control group to the pixel
        // grid by where its visible symbol sits, though the label reserves the same width for all.
        for (name, after, was) in [("Effort", effort.frame, before.0), ("Permissions", permissions.frame, before.1)] {
            XCTAssertEqual(after.minX, was.minX, accuracy: 1, "\(name) moved")
            XCTAssertEqual(after.width, was.width, accuracy: 1, "\(name) changed width")
        }

        // Work In starts the chat in a new worktree.
        workIn.click()
        app.menuItems["New Worktree"].click()
        XCTAssertEqual(workIn.value as? String, "New Worktree")

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
