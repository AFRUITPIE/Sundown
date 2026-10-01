import AppKit
import XCTest

/// Runs the real macOS app against the in-process JSON-RPC fixture (`UITestFixture`). Every launch
/// sets the fixture flag; HostConnection then rejects any attempt to start a daemon or SSH process.
///
/// A launch costs seconds, so each test is one launch walking one flow, checking each step on the
/// way with a message that says which step broke.
class TetherUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// The short fixture chat's answer, and the long `performance` chat's last heading.
    let fixtureAnswer = "Fixture answer from the local transport."
    let longChatEnd = "Section 29: tightening the renderer"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    /// The app on a fixture scenario (the short fixture chat when nil), with the defaults kept in
    /// `suite` when a test relaunches, and any of the fixture's other knobs in `environment`.
    @MainActor
    @discardableResult
    func launch(_ scenario: String? = nil, environment: [String: String] = [:], defaults suite: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        if let scenario { app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = scenario }
        if let suite { app.launchEnvironment["TETHER_UI_TEST_DEFAULTS"] = suite }
        for (key, value) in environment { app.launchEnvironment[key] = value }
        // The windows a debug run left open (or none, if it was stopped) are not restored.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        self.app = app
        return app
    }

    /// Fails, with `note`, if the app is no longer running (a crash).
    @MainActor
    func assertAlive(_ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let alive = app.state == .runningForeground || app.wait(for: .runningForeground, timeout: 3)
        XCTAssertTrue(alive, "the app is no longer running: \(note)", file: file, line: line)
    }

    // MARK: Elements

    /// The static text that says `words`. Not `firstMatch`: once a `TabView` switches tabs, its
    /// shortcut through the tree misses elements a whole query finds.
    @MainActor
    func text(_ words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", words, words)).element(boundBy: 0)
    }

    /// A static text whose words contain `part`.
    @MainActor
    func text(containing part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", part, part)).element(boundBy: 0)
    }

    @MainActor
    var input: XCUIElement { app.descendants(matching: .any)["composer.input"] }

    @MainActor
    func inputText() -> String { String(describing: input.value ?? "") }

    /// The frontmost chat window (not Settings).
    @MainActor
    func mainWindow() -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier != 'com_apple_SwiftUI_Settings_window'")).element(boundBy: 0)
    }

    /// Whether `element`'s middle is inside the chat window: on screen, not merely built somewhere.
    @MainActor
    func isOnScreen(_ element: XCUIElement) -> Bool {
        element.exists && mainWindow().frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    /// Types `message` into the composer and presses Send.
    @MainActor
    func send(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(input.appears(timeout: 10), "no message field", file: file, line: line)
        input.click()
        input.typeText(message)
        app.buttons["composer.send"].click()
    }

    /// One of the inspector's tabs: a tab, or a radio button, however the tab bar reports it; not
    /// View ▸ Inspector's menu item of the same name.
    @MainActor
    func paneTab(_ name: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.tab.rawValue, XCUIElement.ElementType.radioButton.rawValue]
        return app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", name, types))
            .element(boundBy: 0)
    }

    /// The on-screen menu item with this title: the menu bar lists some of the same commands, off screen.
    @MainActor
    func visibleMenuItem(_ title: String) -> XCUIElement {
        let items = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        _ = items.firstMatch.appears(timeout: 5)
        return items.allElementsBoundByIndex.first { $0.isHittable } ?? items.firstMatch
    }

    /// The on-screen button with this title, such as an alert's or a sheet's: in a window or a
    /// dialog, not the Touch Bar's copy of it.
    @MainActor
    func visibleButton(_ title: String) -> XCUIElement {
        let predicate = NSPredicate(format: "title == %@ OR label == %@", title, title)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for query in [app.windows.buttons.matching(predicate), app.dialogs.buttons.matching(predicate)] {
                if let button = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return button }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return app.windows.buttons.matching(predicate).firstMatch
    }

    /// The menu bar's `menu` ▸ `item`, through a submenu when given.
    @MainActor
    func chooseMenuItem(_ menu: String, _ item: String, in submenu: String? = nil) {
        app.menuBars.menuBarItems[menu].click()
        if let submenu { app.menuBars.menuItems[submenu].hover() }
        app.menuBars.menuItems[item].firstMatch.click()
    }

    // MARK: Sidebar and windows

    /// The frontmost window's sidebar, shown if AppKit restored it collapsed (it keeps that state in
    /// the app's own defaults, which a debug run shares).
    @MainActor
    func sidebar() -> XCUIElement {
        let outline = app.windows.firstMatch.outlines["Sidebar"]
        if !outline.appears(timeout: 5) {
            app.menuBars.menuItems["toggleSidebar:"].click()
            XCTAssertTrue(outline.appears(timeout: 5), "no sidebar")
        }
        return outline
    }

    /// A chat's row in the frontmost window's sidebar, by title.
    @MainActor
    func row(_ title: String) -> XCUIElement {
        sidebar().staticTexts[title].firstMatch
    }

    /// Waits for the frontmost window's title to begin with `prefix` (a chat's title, then its
    /// directory and host).
    @MainActor
    func waitForTitle(_ prefix: String, timeout: TimeInterval = 8) -> Bool {
        let window = app.windows.firstMatch
        return waitUntil(timeout) { window.exists && window.title.hasPrefix(prefix) }
    }

    /// Waits until the app's windows are exactly `expected`, by the start of their titles, in any order.
    @MainActor
    func waitForWindows(_ expected: [String], timeout: TimeInterval = 8) -> Bool {
        let counts = Dictionary(expected.map { ($0, 1) }, uniquingKeysWith: +)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.windows.count == expected.count, counts.allSatisfy({ title, count in
                app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", title)).count == count
            }) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    /// Every window's title, for a failure message.
    @MainActor
    func windowTitles() -> String {
        app.windows.allElementsBoundByIndex.map(\.title).joined(separator: " | ")
    }

    // MARK: Settings

    @MainActor
    var settingsWindow: XCUIElement { app.windows["com_apple_SwiftUI_Settings_window"] }

    /// Settings, on `pane` (General, Notifications, Hosts or Advanced).
    @MainActor
    @discardableResult
    func openSettings(_ pane: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let sidebar = settingsWindow.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts[pane].appears(timeout: 10), "no \(pane) in Settings")
        sidebar.staticTexts[pane].click()
        return settingsWindow
    }

    /// Closes Settings by its close button; the chat window becomes key again.
    @MainActor
    func closeSettings() {
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settingsWindow.disappears(timeout: 5), "Settings didn't close")
    }

    /// The control of `query`'s kind on the same row as the text `label`: a grouped form's pop-ups
    /// and switches name their row's title for VoiceOver rather than carrying it as their own label.
    @MainActor
    func control(_ query: XCUIElementQuery, besideLabel label: String) -> XCUIElement? {
        let named = query.matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
        if named.exists { return named }
        let text = settingsWindow.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", label, label)).firstMatch
        guard text.appears(timeout: 5) else { return nil }
        let row = text.frame
        for i in 0..<query.count {
            let candidate = query.element(boundBy: i)
            if abs(candidate.frame.midY - row.midY) < 14 { return candidate }
        }
        return nil
    }

    /// The Settings pop-up labelled `label`.
    @MainActor
    func popUp(_ label: String) -> XCUIElement {
        control(settingsWindow.popUpButtons, besideLabel: label)
            ?? settingsWindow.popUpButtons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Chooses `option` from the Settings pop-up labelled `label`.
    @MainActor
    func choose(_ option: String, from label: String, file: StaticString = #filePath, line: UInt = #line) {
        let popUp = popUp(label)
        XCTAssertTrue(popUp.appears(timeout: 5), "no \(label) pop-up", file: file, line: line)
        popUp.scrollToVisible()
        popUp.click()
        settingsWindow.menuItems[option].click()
    }

    /// A Settings toggle by its label, whichever control type it's exposed as.
    @MainActor
    func toggle(_ label: String) -> XCUIElement {
        for query in [settingsWindow.switches, settingsWindow.checkBoxes] {
            if let match = control(query, besideLabel: label) { return match }
        }
        return settingsWindow.switches.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    func isOn(_ element: XCUIElement) -> Bool {
        (element.value as? NSNumber)?.boolValue ?? ((element.value as? String) == "1")
    }
}

/// Polls `condition` every 0.1 s until it holds or `timeout` passes. XCTest's own waits
/// (`waitForExistence`, `XCTWaiter` with a predicate) check first after a whole second, even when
/// the answer is already yes: across a flow of a hundred steps that was most of its time.
@MainActor
@discardableResult
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

extension XCUIElement {
    /// Whether it exists, or comes to within `timeout`: `waitForExistence`, checking at once.
    @MainActor
    @discardableResult
    func appears(timeout: TimeInterval) -> Bool { waitUntil(timeout) { exists } }

    /// Waits until its frame stops changing (two reads 0.2 s apart agree), as a window settles
    /// after a drag or a row after an animation: with no second-long wait before each check,
    /// a frame read at once can be one from the middle of the motion.
    @MainActor
    func settle(timeout: TimeInterval = 3) {
        var last = exists ? frame : .null
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let now = exists ? frame : .null
            if now == last { return }
            last = now
        }
    }

    /// Clicks it once its arrival has played: a prompt card's buttons come with the card's
    /// materialize transition, and a click the moment one exists can miss. Not by `isHittable`,
    /// which stays false for a card's controls though a click reaches them.
    @MainActor
    func clickWhenReady(timeout: TimeInterval = 5) {
        appears(timeout: timeout)
        Thread.sleep(forTimeInterval: 0.6)
        click()
    }

    /// Whether it's gone, or goes within `timeout`: `waitForNonExistence`, checking at once.
    @MainActor
    @discardableResult
    func disappears(timeout: TimeInterval) -> Bool { waitUntil(timeout) { !exists } }

    /// Scrolls the Settings form until the element is on screen.
    @MainActor
    func scrollToVisible() {
        var tries = 0
        while !isHittable && tries < 10 {
            let form = XCUIApplication().windows["com_apple_SwiftUI_Settings_window"].scrollViews.firstMatch
            form.scroll(byDeltaX: 0, deltaY: frame.midY > form.frame.midY ? -200 : 200)
            tries += 1
        }
    }
}
