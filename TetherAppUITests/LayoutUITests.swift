import XCTest

/// The layouts Settings ▸ Advanced compares, each switched live with the long chat open (switching
/// is where a layout loop would show), and the toolbar's session menus.
final class LayoutUITests: TetherUITestCase {
    /// Tool Calls: Every Call, Summarized and Worked For, at the chat's end and scrolled into its
    /// middle, never leaving the transcript blank; then the sidebar's Activity layout.
    @MainActor
    func testSwitchingLayoutsLive() {
        launch("performance")
        let end = text(longChatEnd)
        XCTAssertTrue(end.waitForExistence(timeout: 20), "the long chat never showed")

        // Model, effort and permissions share one toolbar item.
        let toolbar = mainWindow().toolbars.element(boundBy: 0)
        for menu in ["Model", "Effort", "Permissions"] {
            let button = toolbar.menuButtons.matching(NSPredicate(format: "label BEGINSWITH %@", menu)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(menu) menu in the toolbar")
        }

        // Every Call puts each finished call on a row of its own; Summarized folds runs of them
        // again. The rows are laid out again from the end of the chat with no scrolling needed: the
        // reply that ends it is on screen, not merely built somewhere above, and so is a fold.
        let groups = mainWindow().disclosureTriangles.matching(identifier: "transcript.toolGroup")
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5), "no folded calls in Summarized")
        openSettings("Advanced")
        choose("Every Call", from: "Tool Calls")
        XCTAssertTrue(groups.firstMatch.waitForNonExistence(timeout: 5), "Every Call left calls folded")
        XCTAssertTrue(showsSomething(), "the chat is blank after Every Call")
        choose("Summarized", from: "Tool Calls")
        XCTAssertTrue(end.waitForExistence(timeout: 5), "the chat lost its end after Summarized")
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 5), "Summarized didn't fold the calls again")
        XCTAssertTrue(isOnScreen(end), "the chat is blank: its last reply is at \(end.frame), not in \(mainWindow().frame)")

        // Worked For folds each finished turn's work behind one line, which opens to show it.
        choose("Worked For", from: "Tool Calls")
        closeSettings()
        XCTAssertTrue(showsSomething(), "the chat is blank after Worked For")
        let folds = app.disclosureTriangles.matching(identifier: "transcript.turnWork")
        XCTAssertTrue(folds.firstMatch.waitForExistence(timeout: 5), "Worked For folded nothing")
        guard let fold = folds.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no Worked For line on screen")
        }
        XCTAssertTrue(fold.label.hasPrefix("Worked"), fold.label)
        let calls = app.disclosureTriangles.matching(NSPredicate(format: "identifier IN %@", ["transcript.toolCall", "transcript.toolGroup"]))
        let before = calls.count
        fold.click()
        let deadline = Date().addingTimeInterval(5)
        while calls.count <= before && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(calls.count, before, "the Worked For line opened to no calls")

        // Scrolled into the middle of the chat, switching doesn't blank it either, and the end is
        // there to go back to.
        mainWindow().coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 4000)
        openSettings("Advanced")
        choose("Every Call", from: "Tool Calls")
        choose("Summarized", from: "Tool Calls")
        closeSettings()
        let jump = app.buttons["Jump to Latest"]
        if jump.waitForExistence(timeout: 3) { jump.click() }
        XCTAssertTrue(end.waitForExistence(timeout: 5) && isOnScreen(end), "the chat is blank after switching in its middle")

        // Advanced ▸ Sidebar ▸ Activity lists the chats by day.
        openSettings("Advanced")
        choose("Activity", from: "Layout")
        closeSettings()
        XCTAssertTrue(sidebar().staticTexts["Performance chat 2"].waitForExistence(timeout: 5), "Activity lists no chats")
        assertAlive("after switching to Activity")
    }

    /// Whether a prompt or a heading of the long chat is on screen in the chat window, waiting a
    /// moment for the rows to be laid out again. A blank transcript has none.
    @MainActor
    private func showsSomething() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let root = try? mainWindow().snapshot() {
                let window = root.frame
                var found = false
                func walk(_ element: any XCUIElementSnapshot) {
                    if found { return }
                    if element.elementType == .staticText, let words = element.value as? String,
                       words.hasPrefix("Section ") || words.hasPrefix("Step "),
                       element.frame.width > 0, window.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                        found = true
                    }
                    element.children.forEach(walk)
                }
                walk(root)
                if found { return true }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }
}
