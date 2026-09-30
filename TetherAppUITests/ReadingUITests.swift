import AppKit
import XCTest

/// Reading a chat: text size, Find in Chat, streamed text, and every command being in the menu bar, against the
/// fixture's long performance chat.
final class ReadingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = "performance"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        XCTAssertTrue(heading(app).waitForExistence(timeout: 20))
        return app
    }

    /// The last answer's heading, which the chat opens on.
    @MainActor
    private func heading(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Section 29: tightening the renderer"].firstMatch
    }

    @MainActor
    private func choose(_ app: XCUIApplication, _ menu: String, _ item: String) {
        app.menuBars.menuBarItems[menu].click()
        app.menuBars.menuItems[item].firstMatch.click()
    }

    @MainActor
    func testBiggerAndSmallerResizeTheTranscript() {
        let app = launch()
        let height = heading(app).frame.height

        choose(app, "View", "Bigger")
        let deadline = Date().addingTimeInterval(3)
        while heading(app).frame.height <= height && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(heading(app).frame.height, height)

        // ⌘0, Actual Size, puts it back.
        app.typeKey("0", modifierFlags: .command)
        let back = Date().addingTimeInterval(3)
        while abs(heading(app).frame.height - height) > 0.5 && Date() < back { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(heading(app).frame.height, height, accuracy: 0.5)

        // The sidebar isn't content: it keeps the system's size.
        let row = app.outlines["Sidebar"].staticTexts["Fixture Chat"].firstMatch
        if row.exists {
            let rowHeight = row.frame.height
            choose(app, "View", "Bigger")
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(row.frame.height, rowHeight, accuracy: 0.5)
        }
    }

    /// Native size-change anchoring must keep the end visible after returning from user
    /// scrolling with Jump to Latest, without treating a resize or inspector animation as leaving the end.
    @MainActor
    func testResizingKeepsTheTranscriptAtItsEnd() {
        let app = launch()
        let window = app.windows.firstMatch
        func resize(to width: CGFloat) {
            // Resize from the left border, which stays on screen even when CI's window
            // fills its 1024pt-wide display. An inset point on the right edge hits the
            // transcript rather than the window's resize region; changing height can hit the Dock.
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: window.frame.width - width, dy: 0)),
                       withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
            XCTAssertEqual(window.frame.width, width, accuracy: 2)
        }
        func assertAtEnd() {
            let footer = app.disclosureTriangles.matching(identifier: "transcript.edits").matching(NSPredicate(format: "label == %@", "Edited 1 file, 2 lines added, 2 removed")).firstMatch
            XCTAssertTrue(footer.isHittable, "The last turn's footer must remain visible")
            XCTAssertFalse(app.buttons["Jump to Latest"].exists)
        }
        resize(to: 1000)
        assertAtEnd()
        resize(to: 800)
        assertAtEnd()
        resize(to: 1000)
        assertAtEnd()

        let transcript = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        transcript.scroll(byDeltaX: 0, deltaY: 2000)
        XCTAssertTrue(app.buttons["Jump to Latest"].waitForExistence(timeout: 5))
        app.buttons["Jump to Latest"].click()
        XCTAssertTrue(app.buttons["Jump to Latest"].waitForNonExistence(timeout: 5))
        resize(to: 800)
        assertAtEnd()
        resize(to: 1000)
        assertAtEnd()
        app.typeKey("i", modifierFlags: [.command, .option])
        assertAtEnd()
        app.typeKey("i", modifierFlags: [.command, .option])
        assertAtEnd()
    }

    @MainActor
    func testFindInChatStepsThroughMatches() {
        let app = launch()
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let status = app.staticTexts["find.status"]

        field.typeText("zzz no such text")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.value as? String, "Not Found")

        field.typeKey("a", modifierFlags: .command)
        field.typeText("tightening the renderer")
        // The search runs a moment after typing stops, off the main thread.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { element, _ in
            ((element as? XCUIElement)?.value as? String).map { $0.contains(" of ") } ?? false
        }, object: status)], timeout: 5)
        let first = status.value as? String
        XCTAssertTrue(first?.hasSuffix("of \(first?.split(separator: " ").last ?? "")") == true)
        let parts = (first ?? "").split(separator: " ")
        XCTAssertEqual(parts.count, 3, "\"n of m\", got \(first ?? "nil")")
        let total = Int(parts.last ?? "") ?? 0
        XCTAssertGreaterThan(total, 1)
        // A new search starts at the latest match.
        XCTAssertEqual(first, "\(total) of \(total)")

        app.typeKey("g", modifierFlags: .command)
        XCTAssertEqual(status.value as? String, "1 of \(total)")
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertEqual(status.value as? String, "\(total) of \(total)")

        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
    }

    /// The toolbar can be hidden or customized, so the menu bar has to carry every command.
    @MainActor
    func testTheMenuBarListsEveryCommand() {
        let app = launch()
        let expected: [String: [String]] = [
            "File": ["New Chat", "New Window", "Close"],
            "Edit": ["Find…", "Find Next", "Find Previous"],
            "View": ["Bigger", "Smaller", "Actual Size", "Show Inspector", "Show Toolbar"],
            "Chat": ["Stop", "Open in New Window", "Pin", "Rename…", "Duplicate", "Show in Finder", "Archive", "Delete…"],
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
    }

    /// A reply's words fade in as they stream. The screenshots taken on the way are attached to the
    /// test's report, to look at; what's checked is that the text drawn that way is still ordinary
    /// text once it has arrived, which can be selected and copied.
    @MainActor
    func testStreamedTextFadesInAndStaysSelectable() throws {
        let app = launch()
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Keep going")
        app.buttons["composer.send"].click()

        XCTAssertTrue(app.staticTexts["Section 100: tightening the renderer"].firstMatch.waitForExistence(timeout: 20))
        for i in 1...3 {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "Streaming \(i)"
            shot.lifetime = .keepAlways
            add(shot)
        }

        // Done once Stop gives way to Send.
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 60))
        let quote = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Streaming should cost'"))
            .allElementsBoundByIndex.last { $0.isHittable }
        let last = try XCTUnwrap(quote, "the reply's last block isn't on screen")
        NSPasteboard.general.clearContents()
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).doubleClick()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Streaming")
    }
}
