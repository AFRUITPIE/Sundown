import XCTest

/// A host that can't be reached, and a server that refuses what it's asked.
final class ConnectionUITests: SundownUITestCase {
    /// While the host can't be reached, a card takes the message field's place with Reconnect on
    /// it; once connected, the chat loads.
    @MainActor
    func testTheStatusCardReconnects() {
        launch("connect-failure")
        let card = app.descendants(matching: .any).matching(identifier: "composer.status").firstMatch
        XCTAssertTrue(card.appears(timeout: 15), "no status card while the host is down")
        // The fixture fails twice, retrying on its own in between, so the card says so for a few
        // seconds with Reconnect on it.
        XCTAssertTrue(card.staticTexts["Couldn’t Connect"].appears(timeout: 5), "the card doesn't say it couldn't connect")
        let reconnect = card.buttons["composer.reconnect"]
        XCTAssertTrue(reconnect.exists, "the card has no Reconnect")
        reconnect.click()
        XCTAssertTrue(card.disappears(timeout: 15), "the card stayed after connecting")
        XCTAssertTrue(input.exists, "the message field didn't come back")
        XCTAssertTrue(text(fixtureAnswer).appears(timeout: 15), "the chat didn't load once connected")
    }

    /// `thread/read` and `thread/start` fail (SUNDOWN_UI_TEST_FAIL): the chat says it couldn't
    /// open, and Try Again tries again; a new chat the server refuses says why and keeps its prompt.
    @MainActor
    func testWhatTheServerRefuses() {
        launch(environment: ["SUNDOWN_UI_TEST_FAIL": "thread/read,thread/start"])
        let cannotOpen = text("Couldn’t Open This Chat")
        XCTAssertTrue(cannotOpen.appears(timeout: 20), "no explanation for a chat that can't be read")
        XCTAssertTrue(text(containing: "Fixture thread/read failed").exists, "the reason isn't shown")
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.exists, "no Try Again")
        for attempt in 1...2 {
            // Between tries it may be gone for a moment while the chat is read again.
            XCTAssertTrue(waitUntil(5) { retry.exists && retry.isHittable }, "Try Again went away (try \(attempt)) though the chat still can't be read")
            retry.click()
        }
        assertAlive("after Try Again")
        XCTAssertTrue(cannotOpen.appears(timeout: 10), "the explanation vanished though the chat still can't be read")

        app.typeKey("n", modifierFlags: .command)
        send("Start something")
        assertAlive("after a refused thread/start")
        XCTAssertTrue(text(containing: "thread/start failed").appears(timeout: 10), "nothing says the chat couldn't be started")
        // The draft comes back to the field (#31).
        XCTAssertTrue(waitUntil(5) { self.inputText().contains("Start something") }, "the prompt was lost: \(inputText())")
        // Again, and the window still answers.
        app.buttons["composer.send"].click()
        assertAlive("after sending again")
    }
}
