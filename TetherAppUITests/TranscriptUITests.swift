import AppKit
import XCTest

/// Reading the fixture's long `performance` chat: older pages, Find, text size, prompt navigation,
/// its rows, resizing around it, and a reply streaming into it.
final class TranscriptUITests: TetherUITestCase {
    @MainActor
    private func launchLongChat(environment: [String: String] = [:]) {
        launch("performance", environment: environment)
        XCTAssertTrue(text(longChatEnd).waitForExistence(timeout: 20), "the long chat never showed")
    }

    /// Scrolling up loads the page before the first; Jump to Latest; Find in Chat; Bigger and
    /// Smaller; Previous and Next Prompt in a chat freshly opened.
    @MainActor
    func testScrollingFindingAndPromptNavigation() {
        launchLongChat()
        let latest = text(longChatEnd)
        let jump = app.buttons["Jump to Latest"]
        XCTAssertFalse(jump.exists, "Jump to Latest is offered at the end")

        // The chat opens with its latest 50 items, about three turns; scrolling to the top loads the
        // page before them once the reader stops there. Section 22 is in that page, whatever the
        // turns' sizes. (Page after page to the start: OlderHistoryFixtureTests.)
        let olderPage = app.staticTexts.matching(NSPredicate(format: "value IN %@", (0...22).map { "Section \($0): tightening the renderer" })).firstMatch
        // A point in the transcript: a heading leaves the lazy stack once it scrolls away.
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<20 where !olderPage.exists {
            transcript.scroll(byDeltaX: 0, deltaY: 4000)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(olderPage.exists, "scrolling to the top didn't load the page before")
        // Jump to Latest is offered once the reader is away from the end, and takes them back.
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "no Jump to Latest away from the end")
        jump.click()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "Jump to Latest stayed")
        XCTAssertTrue(latest.waitForExistence(timeout: 5) && latest.isHittable, "Jump to Latest didn't reach the end")

        // Find in Chat steps through its matches.
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F opened no Find bar")
        let status = app.staticTexts["find.status"]
        field.typeText("zzqq")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let notFound = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Not Found'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [notFound], timeout: 3), .completed, "no Not Found: \(String(describing: status.value))")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("tightening")
        // The search runs a moment after typing stops, off the main thread.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS ' of '"), object: status)], timeout: 5)
        let first = status.value as? String ?? ""
        let parts = first.split(separator: " ")
        XCTAssertEqual(parts.count, 3, "\"n of m\", got \(first)")
        let total = Int(parts.last ?? "") ?? 0
        XCTAssertGreaterThan(total, 1, "one match for a heading every turn has")
        // A new search starts at the latest match; Find Next wraps to the first, Previous back.
        XCTAssertEqual(first, "\(total) of \(total)")
        app.typeKey("g", modifierFlags: .command)
        XCTAssertEqual(status.value as? String, "1 of \(total)", "⌘G")
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertEqual(status.value as? String, "\(total) of \(total)", "⇧⌘G")
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3), "Done didn't close the Find bar")

        // View ▸ Bigger scales the transcript, not the sidebar, which keeps the system's size;
        // ⌘0, Actual Size, puts it back.
        let sidebarRow = sidebar().staticTexts["Fixture Chat"].firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        let height = latest.frame.height
        let rowHeight = sidebarRow.frame.height
        chooseMenuItem("View", "Bigger")
        let bigger = Date().addingTimeInterval(3)
        while latest.frame.height <= height && Date() < bigger { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(latest.frame.height, height, "Bigger didn't scale the transcript")
        XCTAssertEqual(sidebarRow.frame.height, rowHeight, accuracy: 0.5, "Bigger scaled the sidebar")
        app.typeKey("0", modifierFlags: .command)
        let back = Date().addingTimeInterval(3)
        while abs(latest.frame.height - height) > 0.5 && Date() < back { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(latest.frame.height, height, accuracy: 0.5, "Actual Size didn't put it back")

        // Chat ▸ Previous Prompt (⌥⌘↑) brings the prompt above the reader's place to the top, one at
        // a time, pressed in quick succession too, and on past the page loaded when the chat opened:
        // in another long chat, opened fresh, so only its first page is in.
        row("Performance chat 1").click()
        XCTAssertTrue(waitForTitle("Performance chat 1"), "the other chat didn't open: \(app.windows.firstMatch.title)")
        XCTAssertTrue(text(longChatEnd).waitForExistence(timeout: 20), "the other chat never showed its end")
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        guard let start = topPrompt() else { return XCTFail("Previous Prompt put no prompt at the top") }
        for _ in 0..<3 { app.typeKey(.upArrow, modifierFlags: [.command, .option]) }
        XCTAssertEqual(topPrompt(), start - 3, "three quick Previous Prompts")
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        XCTAssertEqual(topPrompt(), start - 2, "Next Prompt")
    }

    /// The number of the "Step n" prompt nearest the top of the transcript, once scrolling settles.
    /// Read from one snapshot of the window: a query per prompt cost seconds each time.
    @MainActor
    private func topPrompt() -> Int? {
        var last: Int?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            guard let root = try? mainWindow().snapshot() else { continue }
            var scrollViews: [CGRect] = []
            var prompts: [(top: CGFloat, number: Int)] = []
            func walk(_ element: any XCUIElementSnapshot) {
                if element.elementType == .scrollView { scrollViews.append(element.frame) }
                if element.elementType == .staticText, let words = element.value as? String, words.hasPrefix("Step "),
                   let number = Int(words.dropFirst(5).prefix { $0.isNumber }) {
                    prompts.append((element.frame.minY, number))
                }
                element.children.forEach(walk)
            }
            walk(root)
            // The widest scroll view: the sidebar's is narrower.
            guard let top = scrollViews.max(by: { $0.width < $1.width })?.minY else { continue }
            let number = prompts.filter { $0.top >= top - 2 }.min { $0.top < $1.top }?.number
            if number != nil, number == last { return number }
            last = number
        }
        return last
    }

    /// Resizing keeps the end in view; the inspector in a window as narrow as it goes; a turn's
    /// edited files; tool calls folded and opened.
    @MainActor
    func testRowsResizingAndTheInspector() {
        launchLongChat()
        let window = app.windows.firstMatch

        // Native size-change anchoring keeps the end visible through resizing, after returning from
        // the reader's own scrolling with Jump to Latest, and as the inspector opens and closes.
        // Give the resize border room inside the display: on CI the window initially spans the
        // screen, clipping the native hit regions at both horizontal edges.
        let initialX = window.frame.minX
        // Leave enough room to grow an 800pt local window to the first 1000pt target.
        let inset = max(40, 1000 - window.frame.width + 40)
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20))
        titleBar.click(forDuration: 0.1, thenDragTo: titleBar.withOffset(CGVector(dx: inset, dy: 0)),
                       withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
        // macOS can add its shadow margin when moving a window away from the screen edge.
        // What matters is that its left resize border has moved into the display.
        XCTAssertGreaterThan(window.frame.minX, initialX + inset - 20, "the window didn't move off the screen's edge")
        func resize(to width: CGFloat) {
            // From the left border, which stays on screen even when CI's window fills its
            // 1024pt-wide display. An inset point on the right edge hits the transcript rather than
            // the window's resize region; changing height can hit the Dock. Native edge snapping can
            // leave the first drag a few points short, so it's corrected before asserting.
            for _ in 0..<3 where abs(window.frame.width - width) > 2 {
                let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: window.frame.width - width, dy: 0)),
                           withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
            }
            XCTAssertEqual(window.frame.width, width, accuracy: 2, "the window didn't resize to \(width)")
        }
        let footer = app.disclosureTriangles.matching(identifier: "transcript.edits")
            .matching(NSPredicate(format: "label == %@", "Edited 1 file, 2 lines added, 2 removed")).firstMatch
        func assertAtEnd(_ after: String) {
            XCTAssertTrue(footer.isHittable, "the last turn's footer isn't visible after \(after)")
            XCTAssertFalse(app.buttons["Jump to Latest"].exists, "Jump to Latest is offered after \(after)")
        }
        resize(to: 1000)
        assertAtEnd("widening to 1000")
        resize(to: 800)
        assertAtEnd("narrowing to 800")
        resize(to: 1000)
        assertAtEnd("widening again")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 2000)
        XCTAssertTrue(app.buttons["Jump to Latest"].waitForExistence(timeout: 5), "no Jump to Latest after scrolling up")
        app.buttons["Jump to Latest"].click()
        XCTAssertTrue(app.buttons["Jump to Latest"].waitForNonExistence(timeout: 5))
        resize(to: 800)
        assertAtEnd("narrowing after Jump to Latest")
        resize(to: 1000)
        assertAtEnd("widening after Jump to Latest")
        app.typeKey("i", modifierFlags: [.command, .option])
        assertAtEnd("opening the inspector")
        app.typeKey("i", modifierFlags: [.command, .option])
        assertAtEnd("closing the inspector")

        // Opening and closing the inspector in a window as narrow as it goes. The detail column's
        // minimum used to come from whatever its content measured, and with the composer's + button
        // that made AppKit lay the window out again and again until it gave up and crashed. The drag
        // goes further than the minimum.
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: 600, dy: 0)),
                   withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.1)
        for round in 1...3 {
            app.typeKey("i", modifierFlags: [.command, .option])
            Thread.sleep(forTimeInterval: 1)
            app.typeKey("i", modifierFlags: [.command, .option])
            Thread.sleep(forTimeInterval: 1)
            assertAlive("opening and closing the inspector in a narrow window, round \(round)")
        }
        XCTAssertTrue(window.exists)

        // A turn that edited files ends with a row that lists them; a file opens to its diff.
        let edits = app.disclosureTriangles.matching(identifier: "transcript.edits")
        guard let edited = edits.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no edited-files row on screen")
        }
        XCTAssertTrue(edited.label.hasPrefix("Edited"), edited.label)
        edited.click()
        XCTAssertTrue(app.disclosureTriangles.matching(identifier: "transcript.editedFile").firstMatch.waitForExistence(timeout: 5),
                      "the edited-files row opened to no files")
        XCTAssertTrue(app.buttons["Restore Files…"].exists, "the edited-files row has no Restore Files…")

        // Finished calls are one compact row until opened: then each call is a row of its own (a
        // group holds two at least), with Expand All, Collapse All and complete detail.
        let groups = app.disclosureTriangles.matching(identifier: "transcript.toolGroup")
        guard let group = groups.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no compact tool summary on screen")
        }
        XCTAssertFalse(app.buttons["transcript.expandTools"].exists, "Expand All is offered with every group closed")
        let calls = app.disclosureTriangles.matching(identifier: "transcript.toolCall")
        let before = calls.count
        group.click()
        let deadline = Date().addingTimeInterval(5)
        while calls.count < before + 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(calls.count, before + 2, "the opened group shows no calls")
        let expand = app.buttons["transcript.expandTools"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "an open group offers no Expand All")
        expand.click()
        XCTAssertEqual(expand.label, "Collapse All")
        XCTAssertTrue(app.buttons["code.copy"].firstMatch.waitForExistence(timeout: 3), "expanded calls have no Copy")
        XCTAssertTrue(app.staticTexts["Output"].firstMatch.exists, "expanded calls have no Output")
        expand.click()
        XCTAssertEqual(expand.label, "Expand All")
    }

    /// A reply streaming in: the prompt lifts the transcript, a running call says so, the text fades
    /// in and is ordinary selectable text once it has arrived.
    @MainActor
    func testStreamingAReply() throws {
        // A reply of one section (a burst of calls, the first running for a few seconds, then
        // about 1 KB of Markdown) rather than three: what's checked happens in each.
        launchLongChat(environment: ["TETHER_PERF_REPLY_SECTIONS": "1"])
        let previous = text(longChatEnd)
        let before = previous.frame.minY
        send("Keep going")

        // A running call reads as a row that says it's running (its spinner used to make the whole
        // row read as a progress indicator). A disclosure triangle's value is whether it's open: the
        // status follows the row's words.
        let running = app.windows.firstMatch.disclosureTriangles.matching(NSPredicate(format: "label ENDSWITH 'Running'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 10), "no running call reads as Running")

        // Sending from the end of a full transcript makes room and leaves the new prompt usable.
        let copy = app.buttons["message.copy.perf-sent-1"]
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 8), .completed, "the sent prompt's actions never became usable")
        XCTAssertLessThan(previous.frame.minY, before - 20, "the transcript didn't lift for the prompt")
        XCTAssertLessThan(copy.frame.maxY, input.frame.minY, "the prompt landed under the field")
        XCTAssertTrue(running.waitForNonExistence(timeout: 10), "the call still reads as Running once finished")

        // The reply's words fade in as they stream. The screenshots taken on the way are attached to
        // the report, to look at.
        XCTAssertTrue(app.staticTexts["Section 100: tightening the renderer"].firstMatch.waitForExistence(timeout: 20), "the reply never streamed in")
        for i in 1...3 {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "Streaming \(i)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        // Done once Stop gives way to Send. What's checked is that text drawn that way is still
        // ordinary text once it has arrived, which can be selected and copied.
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 60), "the turn never finished")
        let quote = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Streaming should cost'"))
            .allElementsBoundByIndex.last { $0.isHittable }
        let last = try XCTUnwrap(quote, "the reply's last block isn't on screen")
        NSPasteboard.general.clearContents()
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).doubleClick()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Streaming", "the streamed text isn't selectable")
    }
}
