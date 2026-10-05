import XCTest

/// Hitches during the interactions whose smoothness matters, measured by XCTest while the tests
/// drive the real app: the toolbar's tabs, the sidebar, switching chats, resizing the window,
/// and a long reply streaming in. Each runs against the fixture's performance scenario, a long chat
/// shaped like real work (bursts of tool calls between Markdown answers), with nothing else running.
///
/// Run from the test navigator and read the hitch rate in the test report; Apple counts 10 ms/s or
/// less as good. Switching chats and streaming also report the app's CPU time, memory and disk
/// writes, and how long its signposted intervals took (TetherKit's `Signposts`); launch and idle
/// have tests of their own. "Profile" on a test opens that same run in Instruments. CI skips this
/// class: numbers from a shared virtual machine mean nothing.
final class TetherPerformanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await app?.terminate()
    }

    /// The long chat, open and settled, at a fixed window size.
    /// With TETHER_PERF_ATTACH set to a bundle identifier or an app's path in the runner's environment
    /// (TEST_RUNNER_TETHER_PERF_ATTACH for xcodebuild), the test drives that app instead, launched
    /// beforehand with the same environment: a profiler attached from its start, or another app to
    /// compare against.
    @MainActor
    private func launch(longTurn: Bool = false, replySections: Int? = nil) -> XCUIApplication {
        let app: XCUIApplication
        if let bundleID = ProcessInfo.processInfo.environment["TETHER_PERF_ATTACH"] {
            app = bundleID.hasPrefix("/") ? XCUIApplication(url: URL(fileURLWithPath: bundleID)) : XCUIApplication(bundleIdentifier: bundleID)
            app.activate()
        } else {
            app = XCUIApplication()
            app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
            app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = "performance"
            if longTurn { app.launchEnvironment["TETHER_PERF_LONG_TURN"] = "1" }
            if let replySections { app.launchEnvironment["TETHER_PERF_REPLY_SECTIONS"] = String(replySections) }
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
            app.launch()
        }
        self.app = app
        // The last answer of the long chat, so the transcript has loaded and laid out.
        XCTAssertTrue(app.staticTexts["Section 29: tightening the renderer"].waitForExistence(timeout: 20))
        if ProcessInfo.processInfo.environment["TETHER_PERF_ATTACH"] == nil {
            if !app.outlines["Sidebar"].exists { app.menuBars.menuItems["toggleSidebar:"].click() }
            XCTAssertTrue(app.outlines["Sidebar"].waitForExistence(timeout: 5))
        }
        setWindowSize(app, width: 1000, height: 740)
        return app
    }

    /// The same size every run: AppKit restores the last frame, and how much of the transcript wraps
    /// again on a resize depends on how wide the window started.
    @MainActor
    private func setWindowSize(_ app: XCUIApplication, width: CGFloat, height: CGFloat) {
        let window = app.windows.firstMatch
        let size = window.frame.size
        guard size.width != width || size.height != height else { return }
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: width - size.width, dy: height - size.height)), withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.1)
        XCTAssertEqual(window.frame.width, width, accuracy: 1)
        XCTAssertEqual(window.frame.height, height, accuracy: 1)
        settle()
    }

    /// Hitches in the app's process while `block` runs, five times over, and any `more` metrics.
    @MainActor
    private func measureHitches(_ app: XCUIApplication, also more: [any XCTMetric] = [], _ block: () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTHitchMetric(application: app)] + more, options: options, block: block)
    }

    /// What the app's process used while the block ran: CPU time, the memory it kept, and what it
    /// wrote to disk.
    @MainActor
    private func resources(_ app: XCUIApplication) -> [any XCTMetric] {
        [XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTStorageMetric(application: app)]
    }

    /// The time the app spent in one of its signposted intervals (TetherKit's `Signposts`).
    private func signpost(_ category: String, _ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "com.haydenhong.Tether", category: category, name: name)
    }

    /// Waits for an animation to finish without holding the main thread of the app.
    private func settle(_ seconds: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @MainActor
    func testSwitchingTabs() {
        let app = launch()
        measureHitches(app) {
            app.typeKey("2", modifierFlags: .command)
            settle(0.5)
            app.typeKey("3", modifierFlags: .command)
            settle(0.5)
            app.typeKey("1", modifierFlags: .command)
            settle(0.5)
        }
    }

    @MainActor
    func testSidebarHideAndShow() {
        let app = launch()
        measureHitches(app) {
            app.menuBars.menuItems["toggleSidebar:"].click()
            settle()
            app.menuBars.menuItems["toggleSidebar:"].click()
            settle()
        }
    }

    @MainActor
    func testSwitchingChats() {
        let app = launch()
        let sidebar = app.outlines["Sidebar"]
        // The other two chats aren't live in the fixture's daemon, so each visit reads them again.
        measureHitches(app, also: resources(app) + [signpost("PointsOfInterest", "Chat Switch"), signpost("Transcript", "History Load")]) {
            sidebar.staticTexts["Performance chat 1"].click()
            settle()
            sidebar.staticTexts["Performance chat 2"].click()
            settle()
            sidebar.staticTexts["Fixture Chat"].click()
            settle()
        }
    }

    /// A drag on the window's bottom-right corner, 200 points narrower and back, at a hand's pace.
    /// Each drag starts from wherever the corner is then, and the width has to follow it.
    @MainActor
    func testResizingTheWindow() {
        let app = launch()
        measureResize(app)
    }

    /// The window shell and composer, without transcript content, under the identical drag.
    @MainActor
    func testResizingNewChat() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        settle()
        measureResize(app)
    }

    /// A tool-heavy final turn after its earlier pages are loaded, then viewed at the end.
    @MainActor
    func testResizingLongTurn() {
        let app = launch(longTurn: true)
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let prompt = app.staticTexts["Step 29: look at the next part of the renderer and tighten it up."]
        for _ in 0..<12 where !prompt.exists {
            transcript.scroll(byDeltaX: 0, deltaY: 1800)
            settle()
        }
        // Ensure the page containing the turn's prompt is loaded before measuring at its end.
        XCTAssertTrue(prompt.exists)
        if app.buttons["Jump to Latest"].exists { app.buttons["Jump to Latest"].click() }
        settle()
        measureResize(app)
    }

    /// Resize after eight Markdown replies have accumulated in a still-growing turn. The fixture
    /// keeps sending long enough that every measured drag happens while the turn is active.
    @MainActor
    func testResizingDuringLongLiveTurn() {
        let app = launch(replySections: 40)
        let input = app.descendants(matching: .any)["composer.input"]
        input.click()
        input.typeText("Keep going\r")
        XCTAssertTrue(app.staticTexts["Section 107: tightening the renderer"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["Stop"].exists)
        measureResize(app)
        XCTAssertTrue(app.buttons["Stop"].exists, "The measured turn must still be streaming")
    }

    @MainActor
    private func measureResize(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let width = window.frame.width
        func drag(by dx: CGFloat) {
            // Just inside the corner: a point outside it misses the window.
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
            corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: dx, dy: 0)),
                         withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.1)
        }
        measureHitches(app, also: resources(app) + [XCTClockMetric()]) {
            drag(by: -200)
            XCTAssertEqual(window.frame.width, width - 200, accuracy: 2)
            drag(by: 200)
            XCTAssertEqual(window.frame.width, width, accuracy: 2)
        }
    }

    /// Scroll over the same loaded messages in both directions. Load and warm that region first
    /// so this measures scrolling/layout rather than the timing of history requests.
    @MainActor
    func testScrollingTheTranscript() {
        let app = launch()
        let transcript = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<4 {
            transcript.scroll(byDeltaX: 0, deltaY: 1800)
            settle()
        }
        app.buttons["Jump to Latest"].click()
        settle()
        measureHitches(app, also: resources(app)) {
            for _ in 0..<3 { transcript.scroll(byDeltaX: 0, deltaY: 600) }
            for _ in 0..<3 { transcript.scroll(byDeltaX: 0, deltaY: -600) }
        }
        // The last answer can be taller than the viewport, so its heading needn't be hittable.
        if app.buttons["Jump to Latest"].exists { app.buttons["Jump to Latest"].click() }
        XCTAssertTrue(app.staticTexts["Section 29: tightening the renderer"].exists)
    }

    /// A prompt, then a working reply: tool calls starting and finishing between sections of
    /// Markdown that stream in a few characters a frame, while the transcript follows its end.
    @MainActor
    func testStreamingAReply() {
        let app = launch()
        let input = app.descendants(matching: .any)["composer.input"]
        let stop = app.buttons["Stop"]
        measureHitches(app, also: resources(app) + [signpost("Transcript", "Reply")]) {
            input.click()
            input.typeText("Keep going\r")
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            XCTAssertTrue(stop.waitForNonExistence(timeout: 60))
        }
    }

    /// From launch until the app responds, and until its window's chat has loaded (the Launch
    /// signpost), onto the long chat.
    @MainActor
    func testLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_UI_TEST_SCENARIO"] = "performance"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        self.app = app
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), signpost("PointsOfInterest", "Launch")], options: options) {
            app.launch()
            // Time for the chat to load. Not a query: each one snapshots the app on its main thread,
            // which would slow the launch being measured.
            settle(3)
            app.terminate()
        }
    }

    /// The app left alone with the long chat open: anything that keeps working with nothing to do (a
    /// timer, an animation, an observation loop) shows here. Nothing queries the app while it's
    /// measured, which would wake it.
    @MainActor
    func testIdle() {
        let app = launch()
        settle(2)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: resources(app), options: options) {
            settle(10)
        }
    }
}
