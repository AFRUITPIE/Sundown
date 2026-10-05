import XCTest

/// The tool-call displays in the View menu, each switched live with the long chat open (switching
/// is where a layout loop would show), and the toolbar's session buttons.
final class LayoutUITests: TetherUITestCase {
    /// Tool Calls: Every Call, Summarized and Worked For, at the chat's end and scrolled into its
    /// middle, never leaving the transcript blank.
    @MainActor
    func testSwitchingLayoutsLive() {
        launch("performance")
        let end = text(longChatEnd)
        XCTAssertTrue(end.appears(timeout: 20), "the long chat never showed")

        // Model and Permissions are toolbar buttons.
        let toolbar = mainWindow().toolbars.element(boundBy: 0)
        for name in ["Model", "Permissions"] {
            let button = toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(button.appears(timeout: 5), "no \(name) button in the toolbar")
        }

        // Every Call puts each finished call on a row of its own; Summarized folds runs of them
        // again. The rows are laid out again from the end of the chat with no scrolling needed: the
        // reply that ends it is on screen, not merely built somewhere above, and so is a fold.
        let groups = mainWindow().disclosureTriangles.matching(identifier: "transcript.toolGroup")
        XCTAssertTrue(groups.firstMatch.appears(timeout: 5), "no folded calls in Summarized")
        chooseMenuItem("View", "Every Call")
        XCTAssertTrue(groups.firstMatch.disappears(timeout: 5), "Every Call left calls folded")
        XCTAssertTrue(showsSomething(), "the chat is blank after Every Call")
        chooseMenuItem("View", "Summarized")
        XCTAssertTrue(end.appears(timeout: 5), "the chat lost its end after Summarized")
        XCTAssertTrue(groups.firstMatch.appears(timeout: 5), "Summarized didn't fold the calls again")
        XCTAssertTrue(waitUntil(5) { self.isOnScreen(end) }, "the chat is blank: its last reply is at \(end.frame), not in \(mainWindow().frame)")

        // Worked For folds each finished turn's work behind one line, which opens to show it.
        chooseMenuItem("View", "Worked For")
        XCTAssertTrue(showsSomething(), "the chat is blank after Worked For")
        let folds = app.disclosureTriangles.matching(identifier: "transcript.turnWork")
        XCTAssertTrue(folds.firstMatch.appears(timeout: 5), "Worked For folded nothing")
        var hittableFold: XCUIElement?
        waitUntil(5) { hittableFold = folds.allElementsBoundByIndex.last { $0.isHittable }; return hittableFold != nil }
        guard let fold = hittableFold else {
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
        chooseMenuItem("View", "Every Call")
        chooseMenuItem("View", "Summarized")
        let jump = app.buttons["Jump to Latest"]
        if jump.appears(timeout: 3) { jump.click() }
        XCTAssertTrue(waitUntil(5) { self.isOnScreen(end) }, "the chat is blank after switching in its middle")
        assertAlive("after switching tool calls")
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
