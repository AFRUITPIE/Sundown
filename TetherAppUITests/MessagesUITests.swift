import AppKit
import XCTest

/// What can be done with the messages of the short fixture chat, and the inspector beside it.
final class MessagesUITests: TetherUITestCase {
    /// Copy; Restore Code to Here…; a side question; the inspector's toggle, tabs and shortcuts; a
    /// comment on a change; Fork from Here.
    @MainActor
    func testMessageActionsAndTheInspector() {
        launch()
        let prompt = app.staticTexts["Summarize this project"].firstMatch
        XCTAssertTrue(prompt.appears(timeout: 15), "the fixture chat never showed")

        // A message's actions are icons below it, shown while the pointer is over it.
        NSPasteboard.general.clearContents()
        let copy = app.buttons["message.copy.fixture-user"]
        let fork = app.buttons["message.fork.fixture-user"]
        prompt.hover()
        XCTAssertTrue(copy.isHittable, "the prompt's Copy isn't shown on hover")
        let forkBefore = fork.frame
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Summarize this project", "Copy on the prompt")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(fork.frame.minX, forkBefore.minX, accuracy: 0.5, "Copy's checkmark moved the icons beside it")
        NSPasteboard.general.clearContents()
        app.buttons["message.copy.fixture-answer"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), fixtureAnswer, "Copy on the answer")

        // Restore Code to Here… says which files go back before doing it, and then can't again.
        // From the blank beside the bubble: its words are selectable text, with the text's own menu.
        let besidePrompt = prompt.coordinate(withNormalizedOffset: CGVector(dx: -0.6, dy: 0.5))
        besidePrompt.rightClick()
        visibleMenuItem("Restore Code to Here…").click()
        XCTAssertTrue(app.staticTexts["Restore Files to Before This Message?"].appears(timeout: 5), "Restore Code didn't ask first")
        XCTAssertTrue(text(containing: "App.swift, README.md").exists, "the confirmation doesn't name the files")
        visibleButton("Restore").click()
        XCTAssertTrue(app.staticTexts["Restore Files to Before This Message?"].disappears(timeout: 5))
        besidePrompt.rightClick()
        visibleMenuItem("Restore Code to Here…").click()
        XCTAssertTrue(app.staticTexts["No Files to Restore"].appears(timeout: 5), "a second Restore offered files again")
        visibleButton("OK").click()

        // ⌥⌘; asks a side question: answered in the sheet, not added to the chat.
        app.typeKey(";", modifierFlags: [.command, .option])
        let field = app.descendants(matching: .any)["sideQuestion.field"]
        XCTAssertTrue(field.appears(timeout: 5), "⌥⌘; opened no side question")
        field.typeText("What did we decide?")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(text(containing: "A side answer").appears(timeout: 5), "the side question wasn't answered")
        visibleButton("Done").click()
        XCTAssertFalse(text(containing: "What did we decide?").exists, "the side question went into the chat")

        // The inspector opens from its toolbar button, and its tabs (SwiftUI's own) switch panes.
        // The fixture's store is fresh, so it starts closed, with no tabs.
        let mcp = paneTab("MCP")
        XCTAssertFalse(mcp.exists, "the inspector started open")
        app.buttons["Inspector"].click()
        XCTAssertTrue(mcp.appears(timeout: 5), "the Inspector button didn't open it")
        mcp.click()
        let noServers = app.staticTexts["No MCP Servers"]
        XCTAssertTrue(noServers.appears(timeout: 5), "the MCP tab didn't show its pane")
        XCTAssertEqual((mcp.value as? NSNumber)?.intValue, 1, "MCP isn't the selected tab")
        XCTAssertEqual((paneTab("Tasks").value as? NSNumber)?.intValue, 0, "Tasks is still selected")
        // ⌥⌘I hides it, and shows it again on the same pane.
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(noServers.disappears(timeout: 5), "⌥⌘I didn't hide the inspector")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(noServers.appears(timeout: 5), "⌥⌘I didn't reopen it on MCP")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(noServers.disappears(timeout: 5))

        // ⌥⌘4 opens it on Changes: what differs from the last commit. Each line is a button, its
        // text the value; a comment is written in a popover beside it and goes to Claude.
        app.typeKey("4", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["App.swift"].appears(timeout: 10), "⌥⌘4 didn't show Changes")
        let changed = app.buttons.matching(NSPredicate(format: "value == %@", "let greeting = \"Hello, Tether\"")).firstMatch
        XCTAssertTrue(changed.appears(timeout: 5), "the changed line isn't a button")
        changed.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.appears(timeout: 5), "clicking a line opened no comment popover")
        let comment = popover.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
        XCTAssertTrue(comment.appears(timeout: 5))
        comment.typeText("Use the app's name from its bundle")
        popover.buttons["Add"].click()
        let sendComment = app.windows.firstMatch.buttons["Send Comment"]
        XCTAssertTrue(sendComment.appears(timeout: 5), "no Send Comment")
        XCTAssertTrue(sendComment.isEnabled)
        // By its leading edge: on CI's 1024-point screen the window, with the inspector open, is
        // wider than the screen, and the button's middle is off it.
        sendComment.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        XCTAssertTrue(text(containing: "Sources/App.swift:2").appears(timeout: 10), "the comment never reached the chat")

        // Fork from Here makes a new chat from the conversation so far and opens it.
        let rows = sidebar().outlineRows.containing(.staticText, identifier: "Fixture Chat")
        XCTAssertTrue(rows.firstMatch.appears(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        let answer = text(fixtureAnswer)
        answer.hover()
        app.buttons["message.fork.fixture-answer"].click()
        let deadline = Date().addingTimeInterval(5)
        while rows.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(rows.count, 2, "Fork from Here made no chat")
        // The fork is the newer chat, so it heads the list, and it's the one showing.
        XCTAssertTrue(rows.element(boundBy: 0).isSelected, "the fork isn't the chat showing")
        XCTAssertFalse(rows.element(boundBy: 1).isSelected)
    }
}
