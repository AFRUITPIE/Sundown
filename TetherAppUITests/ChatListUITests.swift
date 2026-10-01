import XCTest

/// The sidebar's chats and the Chat menu's actions on them, against the `performance` scenario's
/// three chats, each one turn long (TETHER_PERF_TURNS).
final class ChatListUITests: TetherUITestCase {
    /// Search; a draft kept per chat; Next and Previous Chat; Pin; Archive and Show ▸ Archived;
    /// Rename; Duplicate; Delete.
    @MainActor
    func testManagingChats() {
        launch("performance", environment: ["TETHER_PERF_TURNS": "1"])
        let outline = sidebar()
        XCTAssertTrue(row("Performance chat 1").waitForExistence(timeout: 20), "the chats never showed")
        XCTAssertTrue(waitForTitle("Fixture Chat"), "the window isn't on the fixture chat: \(app.windows.firstMatch.title)")

        // Search narrows the list, and clearing it brings every chat back.
        let search = app.windows.firstMatch.searchFields.firstMatch
        XCTAssertTrue(search.exists, "the sidebar has no search field")
        search.click()
        search.typeText("zzqq")
        XCTAssertTrue(row("Fixture Chat").waitForNonExistence(timeout: 5), "a search for nothing still lists the chat")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Fixture")
        XCTAssertTrue(row("Fixture Chat").waitForExistence(timeout: 5), "a search for its title doesn't list the chat")
        XCTAssertFalse(row("Performance chat 1").exists, "a search for Fixture lists another chat")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(row("Performance chat 1").waitForExistence(timeout: 5), "clearing the search didn't list every chat again")

        // A draft belongs to its chat: gone while another chat shows, back with its own.
        input.click()
        input.typeText("half a thought")
        row("Performance chat 1").click()
        XCTAssertTrue(waitForTitle("Performance chat 1"), "the chat didn't switch")
        XCTAssertFalse(inputText().contains("half a thought"), "the draft followed into another chat")
        row("Fixture Chat").click()
        XCTAssertTrue(waitForTitle("Fixture Chat"), "the chat didn't switch back")
        XCTAssertTrue(inputText().contains("half a thought"), "the draft was lost: \(inputText())")

        // Chat ▸ Next Chat (⌥⌘]) and Previous Chat (⌥⌘[) step through the sidebar's chats.
        row("Performance chat 1").click()
        XCTAssertTrue(waitForTitle("Performance chat 1"))
        app.typeKey("]", modifierFlags: [.command, .option])
        XCTAssertTrue(waitForTitle("Performance chat 2"), "Next Chat: \(app.windows.firstMatch.title)")
        app.typeKey("[", modifierFlags: [.command, .option])
        XCTAssertTrue(waitForTitle("Performance chat 1"), "Previous Chat: \(app.windows.firstMatch.title)")

        // Chat ▸ Pin (⌥⌘P) puts the chat in Pinned at the top of the sidebar; again takes it out.
        let pinned = outline.staticTexts["Pinned"]
        XCTAssertFalse(pinned.exists, "something is pinned already")
        app.typeKey("p", modifierFlags: [.command, .option])
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "⌥⌘P pinned nothing")
        app.typeKey("p", modifierFlags: [.command, .option])
        XCTAssertTrue(pinned.waitForNonExistence(timeout: 5), "⌥⌘P again didn't unpin")

        // Archive takes a chat out of the list without deleting it; Show ▸ Archived lists it (and
        // the open chat, whatever it says, but no other), and Unarchive puts it back.
        let archived = row("Performance chat 2")
        archived.rightClick()
        visibleMenuItem("Archive").click()
        XCTAssertTrue(archived.waitForNonExistence(timeout: 5), "Archive left the chat listed")
        chooseMenuItem("View", "Archived", in: "Show")
        XCTAssertTrue(archived.waitForExistence(timeout: 5), "Show ▸ Archived doesn't list it")
        XCTAssertFalse(outline.staticTexts["Fixture Chat"].exists, "Show ▸ Archived lists a chat that isn't")
        archived.rightClick()
        visibleMenuItem("Unarchive").click()
        XCTAssertTrue(archived.waitForNonExistence(timeout: 5), "Unarchive left it among the archived")
        chooseMenuItem("View", "All Chats", in: "Show")
        XCTAssertTrue(archived.waitForExistence(timeout: 5), "the unarchived chat isn't listed again")

        // Chat ▸ Rename… opens with the current title, ready to replace.
        chooseMenuItem("Chat", "Rename…")
        let field = app.sheets.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Rename… opened no alert")
        XCTAssertEqual(field.value as? String, "Performance chat 1")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed Chat")
        visibleButton("Rename").click()
        XCTAssertTrue(row("Renamed Chat").waitForExistence(timeout: 5), "the sidebar doesn't show the new title")
        XCTAssertFalse(row("Performance chat 1").exists, "the old title is still listed")

        // Duplicate makes a copy, with the same title.
        let copies = outline.staticTexts.matching(identifier: "Renamed Chat")
        let before = copies.count
        row("Renamed Chat").rightClick()
        visibleMenuItem("Duplicate").click()
        let duplicated = Date().addingTimeInterval(5)
        while copies.count == before && Date() < duplicated { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(copies.count, before + 1, "Duplicate made no copy")

        // Delete asks first; Cancel keeps the chat.
        let doomed = row("Performance chat 2")
        doomed.rightClick()
        visibleMenuItem("Delete…").click()
        XCTAssertTrue(app.staticTexts["Delete “Performance chat 2”?"].waitForExistence(timeout: 5), "Delete didn't ask first")
        visibleButton("Cancel").click()
        XCTAssertTrue(doomed.exists, "Cancel deleted the chat")
        doomed.rightClick()
        visibleMenuItem("Delete…").click()
        visibleButton("Delete").click()
        XCTAssertTrue(doomed.waitForNonExistence(timeout: 5), "Delete left the chat")
    }
}
