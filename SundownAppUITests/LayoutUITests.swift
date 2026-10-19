import XCTest

/// The tool-call displays in the View menu, each switched live with the long chat open (switching
/// is where a layout loop would show), and the toolbar's session buttons.
final class LayoutUITests: SundownUITestCase {
    /// Tool Calls: Every Call, Summarized and Worked For, at the chat's end and scrolled into its
    /// middle, never leaving the transcript blank.
    @MainActor
    func testSwitchingLayoutsLive() {
        launch("performance")
        let end = text(longChatEnd)
        XCTAssertTrue(end.appears(timeout: 20), "the long chat never showed")

        // Model is a toolbar button; Permissions is hidden until Customize Toolbar adds it.
        let toolbar = mainWindow().toolbars.element(boundBy: 0)
        let model = toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model'")).firstMatch
        XCTAssertTrue(model.appears(timeout: 5), "no Model button in the toolbar")
        let permissions = toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Permissions'")).firstMatch
        XCTAssertFalse(permissions.exists, "Permissions is in the default toolbar")

        // Every Call puts each finished call on a row of its own; Summarized folds runs of them
        // again. The rows are laid out again from the end of the chat with no scrolling needed: the
        // reply that ends it is on screen, not merely built somewhere above, and so is a fold.
        let groups = mainWindow().disclosureTriangles.matching(identifier: "transcript.toolGroup")
        XCTAssertTrue(groups.firstMatch.appears(timeout: 5), "no folded calls in Summarized")
        chooseMenuItem("View", "Every Call")
        XCTAssertTrue(groups.firstMatch.disappears(timeout: 5), "Every Call left calls folded")
        XCTAssertTrue(showsSomething(), "the chat is blank after Every Call")
        // At the end it stays there, though the list is made again at a very different height.
        XCTAssertTrue(waitUntil(5) { self.isOnScreen(end) }, "Every Call left the end: the last reply isn't on screen")
        chooseMenuItem("View", "Summarized")
        XCTAssertTrue(end.appears(timeout: 5), "the chat lost its end after Summarized")
        XCTAssertTrue(groups.firstMatch.appears(timeout: 5), "Summarized didn't fold the calls again")
        XCTAssertTrue(waitUntil(5) { self.isOnScreen(end) }, "the chat lost its end after Summarized: its last reply is at \(String(describing: try? end.snapshot().frame)), not in \(mainWindow().frame)")

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
        waitUntil(5) { calls.count > before }
        XCTAssertGreaterThan(calls.count, before, "the Worked For line opened to no calls")

        // Scrolled into the middle of the chat, switching doesn't blank it either, and the end is
        // there to go back to.
        // The message at the top stays on screen through each.
        mainWindow().coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 4000)
        var place = topMessage(in: messageTops())
        XCTAssertNotNil(place, "no message on screen after scrolling into the middle")
        for display in ["Every Call", "Summarized"] {
            chooseMenuItem("View", display)
            let tops = messageTops()
            if let place {
                XCTAssertTrue(isVisible(place.key, in: tops), "\(display) in the middle lost the reader's place: \(place.key) isn't on screen, \(tops)")
            }
            place = topMessage(in: tops)
        }
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
                    if let words = element.messageWords,
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
