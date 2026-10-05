import XCTest

/// Chat windows and the host windows, against the `performance` scenario's three chats, each one
/// turn long (SUNDOWN_PERF_TURNS): there is something to switch to, and little to query.
final class WindowsUITests: SundownUITestCase {
    @MainActor
    private func launchThreeChats(defaults suite: String) {
        launch("performance", environment: ["SUNDOWN_PERF_TURNS": "1"], defaults: suite)
        XCTAssertTrue(row("Performance chat 1").appears(timeout: 20), "the chats never showed")
    }

    /// A new window keeps its own chat; New Chat in a second window; Open in New Window; a
    /// double-click opening a window; the Connection Log window; the
    /// last chat reopening after a relaunch.
    @MainActor
    func testWindows() {
        let suite = "sundown.uitest.windows.\(UUID().uuidString)"
        launchThreeChats(defaults: suite)
        XCTAssertTrue(waitForWindows(["Fixture Chat"]), "not one window on the fixture chat: \(windowTitles())")

        // File ▸ New Window opens on New Chat, in front; choosing a chat there leaves the other
        // window alone.
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(waitForWindows(["Fixture Chat", "New Chat"]), "⌥⌘N: \(windowTitles())")
        row("Performance chat 1").click()
        XCTAssertTrue(waitForWindows(["Fixture Chat", "Performance chat 1"]), "a chat chosen in the new window: \(windowTitles())")
        // New Chat in that second window, now on a chat. With two windows, AppKit's toolbar
        // asserted (`-[NSToolbar _itemAtIndex:]`) and took the app down when one left its chat.
        app.typeKey("n", modifierFlags: .command)
        assertAlive("⌘N in a second window that opened a chat")
        XCTAssertTrue(waitForWindows(["Fixture Chat", "New Chat"]), "⌘N in the second window: \(windowTitles())")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindows(["Fixture Chat"]), "⌘W: \(windowTitles())")

        // Chat ▸ Open in New Window opens a second window on the chat already on screen.
        chooseMenuItem("Chat", "Open in New Window")
        XCTAssertTrue(waitForWindows(["Fixture Chat", "Fixture Chat"]), "Open in New Window: \(windowTitles())")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindows(["Fixture Chat"]), "⌘W: \(windowTitles())")

        // Double-clicking a chat opens it in a window of its own, as Mail opens a message.
        row("Performance chat 1").doubleClick()
        XCTAssertTrue(waitForWindows(["Performance chat 1", "Performance chat 1"]), "double-click: \(windowTitles())")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindows(["Performance chat 1"]), "⌘W: \(windowTitles())")

        // Host ▸ Show Connection Log opens the log in a window of its own.
        chooseMenuItem("Host", "Show Connection Log")
        XCTAssertTrue(waitForWindows(["Performance chat 1", "Connection Log"]), "Show Connection Log: \(windowTitles())")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindows(["Performance chat 1"]), "⌘W on the log: \(windowTitles())")

        // The first window of a launch opens on the last chat.
        row("Performance chat 2").click()
        XCTAssertTrue(waitForWindows(["Performance chat 2"]), "choosing a chat: \(windowTitles())")
        app.terminate()
        launchThreeChats(defaults: suite)
        XCTAssertTrue(waitForWindows(["Performance chat 2"], timeout: 10), "the last chat didn't reopen: \(windowTitles())")
    }
}
