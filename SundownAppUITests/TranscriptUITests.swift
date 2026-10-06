import AppKit
import XCTest

/// Reading the fixture's long `performance` chat: older pages, Find, text size, prompt navigation,
/// its rows, resizing around it, and a reply streaming into it.
final class TranscriptUITests: SundownUITestCase {
    @MainActor
    private func launchLongChat(environment: [String: String] = [:]) {
        launch("performance", environment: environment)
        XCTAssertTrue(text(longChatEnd).appears(timeout: 20), "the long chat never showed")
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
        let olderPage = app.text(containingAnyOf: (0...22).map { "Section \($0): tightening the renderer" })
        // A point in the transcript: a heading leaves the lazy stack once it scrolls away.
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<20 where !olderPage.exists {
            transcript.scroll(byDeltaX: 0, deltaY: 4000)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(olderPage.exists, "scrolling to the top didn't load the page before")
        // Jump to Latest is offered once the reader is away from the end, and takes them back.
        XCTAssertTrue(jump.appears(timeout: 5), "no Jump to Latest away from the end")
        jump.click()
        XCTAssertTrue(jump.disappears(timeout: 5), "Jump to Latest stayed")
        XCTAssertTrue(waitUntil(5) { latest.exists && latest.isHittable }, "Jump to Latest didn't reach the end")

        // Find in Chat steps through its matches.
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["find.field"]
        XCTAssertTrue(field.appears(timeout: 5), "⌘F opened no Find bar")
        let status = app.staticTexts["find.status"]
        field.typeText("zzqq")
        XCTAssertTrue(status.appears(timeout: 3))
        XCTAssertTrue(waitUntil(3) { status.value as? String == "Not Found" }, "no Not Found: \(String(describing: status.value))")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("tightening")
        // The search runs a moment after typing stops, off the main thread.
        waitUntil(5) { (status.value as? String)?.contains(" of ") == true }
        // The count can still change while the transcript settles (a slower runner): read it once
        // it has held for half a second.
        var held = status.value as? String ?? ""
        waitUntil(5) {
            Thread.sleep(forTimeInterval: 0.5)
            let now = status.value as? String ?? ""
            defer { held = now }
            return now == held
        }
        let first = status.value as? String ?? ""
        let parts = first.split(separator: " ")
        XCTAssertEqual(parts.count, 3, "\"n of m\", got \(first)")
        let total = Int(parts.last ?? "") ?? 0
        XCTAssertGreaterThan(total, 1, "one match for a heading every turn has")
        // A new search starts at the latest match; Find Next wraps to the first, Previous back.
        XCTAssertEqual(first, "\(total) of \(total)")
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { (status.value as? String)?.hasPrefix("1 of ") == true }, "⌘G: \(String(describing: status.value))")
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(3) {
            let parts = (status.value as? String ?? "").split(separator: " ")
            return parts.count == 3 && parts[0] == parts[2]
        }, "⇧⌘G: \(String(describing: status.value))")
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(field.disappears(timeout: 3), "Done didn't close the Find bar")

        // View ▸ Bigger scales the transcript, not the sidebar, which keeps the system's size;
        // ⌘0, Actual Size, puts it back.
        let sidebarRow = sidebar().staticTexts["Fixture Chat"].firstMatch
        XCTAssertTrue(latest.appears(timeout: 5))
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
        XCTAssertTrue(text(longChatEnd).appears(timeout: 20), "the other chat never showed its end")
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        guard let start = topPrompt() else { return XCTFail("Previous Prompt put no prompt at the top") }
        // A known fault, in the app: from the end of a freshly opened long chat the first Previous
        // Prompt lands on Step 1 (the oldest), not on the last prompt, and the ones after it end on
        // Step 25 rather than three before where the first went.
        XCTExpectFailure("The first Previous Prompt in a freshly opened long chat lands on the oldest prompt", options: nonStrict) {
            XCTAssertGreaterThan(start, 20, "the first Previous Prompt went to Step \(start)")
        }
        for _ in 0..<3 { app.typeKey(.upArrow, modifierFlags: [.command, .option]) }
        let three = topPrompt()
        XCTAssertNotNil(three, "three quick Previous Prompts left no prompt at the top")
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        XCTAssertEqual(topPrompt(), three.map { $0 + 1 }, "Next Prompt")
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
                if element.elementType == .scrollView, element.identifier != "composer.scroll" { scrollViews.append(element.frame) }
                // A prompt is a text view holding its text; the message field isn't one.
                if element.elementType == .staticText || element.elementType == .textView && element.identifier != "composer.input",
                   let words = element.value as? String, words.hasPrefix("Step "),
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

    /// Resizing keeps the end in view; a turn's edited files; tool calls folded and opened; the
    /// tabs in a window as narrow as it goes.
    @MainActor
    func testRowsResizingAndTheTabs() {
        launchLongChat()
        let window = app.windows.firstMatch

        // Native size-change anchoring keeps the end visible through resizing, after returning from
        // the reader's own scrolling with Jump to Latest, and as the tabs switch.
        // Give the resize border room inside the display: on CI the window initially spans the
        // screen, clipping the native hit regions at both horizontal edges.
        window.settle()
        let initialX = window.frame.minX
        // Leave enough room to grow an 800pt local window to the first 1000pt target.
        let inset = max(40, 1000 - window.frame.width + 40)
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20))
        titleBar.click(forDuration: 0.1, thenDragTo: titleBar.withOffset(CGVector(dx: inset, dy: 0)),
                       withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
        window.settle()
        // On CI's 1024pt display the pinned 1000pt window has no room to move; its left border is
        // on screen either way, so the move is best effort and only the border has to be reachable.
        XCTAssertGreaterThanOrEqual(window.frame.minX, initialX - 1, "the window moved off the screen's left edge")
        func resize(to width: CGFloat) {
            // From the left border, which stays on screen even when CI's window fills its
            // 1024pt-wide display. An inset point on the right edge hits the transcript rather than
            // the window's resize region; changing height can hit the Dock. Native edge snapping can
            // leave the first drag a few points short, so it's corrected before asserting.
            for _ in 0..<3 where abs(window.frame.width - width) > 2 {
                let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: window.frame.width - width, dy: 0)),
                           withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
                window.settle()
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
        resize(to: 860)
        assertAtEnd("narrowing to 860")
        resize(to: 1000)
        assertAtEnd("widening again")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 2000)
        XCTAssertTrue(app.buttons["Jump to Latest"].appears(timeout: 5), "no Jump to Latest after scrolling up")
        app.buttons["Jump to Latest"].click()
        XCTAssertTrue(app.buttons["Jump to Latest"].disappears(timeout: 5))
        resize(to: 860)
        assertAtEnd("narrowing after Jump to Latest")
        resize(to: 1000)
        assertAtEnd("widening after Jump to Latest")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(input.disappears(timeout: 5), "⌘2 didn't leave the chat")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(input.appears(timeout: 5), "⌘1 didn't come back to the chat")
        XCTAssertTrue(waitUntil(5) { footer.isHittable }, "the chat isn't at its end after switching to Tasks and back")
        // At its end, it doesn't offer to jump there.
        XCTAssertFalse(app.buttons["Jump to Latest"].exists, "Jump to Latest is offered after switching to Tasks and back")
        // Back where it started, 1000 points wide, moved by the title bar's empty stretch between
        // the window buttons and the sidebar toggle.
        resize(to: 1000)
        let bar = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 120, dy: 20))
        bar.click(forDuration: 0.1, thenDragTo: bar.withOffset(CGVector(dx: initialX - window.frame.minX, dy: 0)),
                  withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
        window.settle()

        // A turn that edited files ends with a row that lists them; a file opens to its diff.
        let edits = app.disclosureTriangles.matching(identifier: "transcript.edits")
        var hittableEdits: XCUIElement?
        waitUntil(5) { hittableEdits = edits.allElementsBoundByIndex.last { $0.isHittable }; return hittableEdits != nil }
        guard let edited = hittableEdits else {
            return XCTFail("no edited-files row on screen")
        }
        XCTAssertTrue(edited.label.hasPrefix("Edited"), edited.label)
        edited.click()
        XCTAssertTrue(app.disclosureTriangles.matching(identifier: "transcript.editedFile").firstMatch.appears(timeout: 5),
                      "the edited-files row opened to no files")
        XCTAssertTrue(app.buttons["Restore Files…"].exists, "the edited-files row has no Restore Files…")

        // Finished calls are one compact row until opened: then each call is a row of its own (a
        // group holds two at least), with Expand All, Collapse All and complete detail.
        let groups = app.disclosureTriangles.matching(identifier: "transcript.toolGroup")
        // Clear of the toolbar above and the bottom bar floating over the transcript below: over
        // either, XCUITest still calls a row hittable but the click lands on the bar. On CI's
        // smaller screen the opened edits row pushes the groups up under the toolbar, so one is
        // scrolled down into the clear band.
        let top = window.frame.minY + 160, bottom = window.frame.maxY - 180
        func clearGroup() -> XCUIElement? {
            groups.allElementsBoundByIndex.last { $0.isHittable && $0.frame.midY > top && $0.frame.midY < bottom }
        }
        for _ in 0..<10 where clearGroup() == nil {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 120)
        }
        guard let group = clearGroup() else {
            return XCTFail("no compact tool summary on screen")
        }
        XCTAssertFalse(app.buttons["transcript.expandTools"].exists, "Expand All is offered with every group closed")
        let calls = app.disclosureTriangles.matching(identifier: "transcript.toolCall")
        let before = calls.count
        group.click()
        let deadline = Date().addingTimeInterval(8)
        while calls.count < before + 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(calls.count, before + 2, "the opened group shows no calls")
        let expand = app.buttons["transcript.expandTools"].firstMatch
        XCTAssertTrue(expand.appears(timeout: 3), "an open group offers no Expand All")
        // Above the group's calls, so the group opening at the end pushes it up under the toolbar,
        // where XCUITest still calls it hittable and a click lands on the toolbar: scrolled down
        // into the open.
        for _ in 0..<10 where expand.frame.minY < window.frame.minY + 160 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 120)
        }
        expand.click()
        XCTAssertTrue(waitUntil(3) { expand.label == "Collapse All" }, "Expand All didn't turn into Collapse All")
        XCTAssertTrue(app.buttons["code.copy"].firstMatch.appears(timeout: 3), "expanded calls have no Copy")
        XCTAssertTrue(app.staticTexts["Output"].firstMatch.exists, "expanded calls have no Output")
        expand.click()
        XCTAssertTrue(waitUntil(3) { expand.label == "Expand All" }, "Collapse All didn't turn back into Expand All")

        // Switching tabs in a window as narrow as it goes. The detail column's minimum used to come
        // from whatever its content measured, and with the composer's + button that made AppKit lay
        // the window out again and again until it gave up and crashed. The drag goes further than
        // the minimum.
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: 600, dy: 0)),
                   withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.1)
        for round in 1...3 {
            app.typeKey("3", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            app.typeKey("1", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            assertAlive("switching tabs in a narrow window, round \(round)")
        }
        XCTAssertTrue(window.exists)
    }

    /// A reply streaming in: the prompt lifts the transcript, a running call says so, the text fades
    /// in and is ordinary selectable text once it has arrived.
    @MainActor
    func testStreamingAReply() throws {
        // A reply of one section (a burst of calls, the first running for a few seconds, then
        // about 1 KB of Markdown) rather than three: what's checked happens in each.
        launchLongChat(environment: ["SUNDOWN_PERF_REPLY_SECTIONS": "1"])
        let previous = text(longChatEnd)
        let before = previous.frame.minY
        send("Keep going")

        // A running call reads as a row that says it's running (its spinner used to make the whole
        // row read as a progress indicator). A disclosure triangle's value is whether it's open: the
        // status follows the row's words.
        let running = app.windows.firstMatch.disclosureTriangles.matching(NSPredicate(format: "label ENDSWITH 'Running'")).firstMatch
        XCTAssertTrue(running.appears(timeout: 10), "no running call reads as Running")

        // Sending from the end of a full transcript makes room and leaves the new prompt usable.
        let copy = app.buttons["message.copy.perf-sent-1"]
        let sent = text("Keep going")
        XCTAssertTrue(hover(over: sent) { app.buttons["message.fork.perf-sent-1"].isHittable }, "the sent prompt's actions never became usable")
        XCTAssertLessThan(previous.frame.minY, before - 20, "the transcript didn't lift for the prompt")
        XCTAssertLessThan(copy.frame.maxY, input.frame.minY, "the prompt landed under the field")
        XCTAssertTrue(running.disappears(timeout: 10), "the call still reads as Running once finished")

        // The reply's words fade in as they stream. The screenshots taken on the way are attached to
        // the report, to look at.
        XCTAssertTrue(text(containing: "Section 100: tightening the renderer").appears(timeout: 20), "the reply never streamed in")
        for i in 1...3 {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "Streaming \(i)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        // Done once Stop gives way to Send. What's checked is that text drawn that way is still
        // ordinary text once it has arrived, which can be selected and copied.
        XCTAssertTrue(app.buttons["Stop"].disappears(timeout: 60), "the turn never finished")
        // The reply ends with its quote, its text view's last line. Found by its heading: what
        // XCUITest reads of a text view's value stops after its first few hundred characters.
        let replies = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Section 100: tightening the renderer'"))
        var reply: XCUIElement?
        // Looked for until found: as the turn ends its row is settled, and an element listed a
        // moment before may no longer resolve. On screen rather than hittable: a message is one
        // text view, whose middle can be a code box's.
        waitUntil(5) {
            reply = replies.allElementsBoundByIndex.last { self.isOnScreen($0) }
            return reply != nil
        }
        let last = try XCTUnwrap(reply, "the reply isn't on screen: \(replies.allElementsBoundByIndex.map(\.frame)) in \(mainWindow().frame)")
        // Where the turn's end leaves it, not where it was as the last row went in.
        last.settle()
        NSPasteboard.general.clearContents()
        // Its first word, past the quote's bar and indent.
        last.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 40, dy: -8)).doubleClick()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Streaming", "the streamed text isn't selectable")
    }
}
