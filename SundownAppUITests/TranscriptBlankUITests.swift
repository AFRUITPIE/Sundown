import AppKit
import XCTest

/// The transcript never goes blank, and stays at its end or the reader's place (2026-10-09).
///
/// With replies from a line to thousands of points tall (`SUNDOWN_PERF_VARIED`), the lazy stack's
/// estimate of the rows it hasn't built is far off, and a scroll to an estimated place left it past
/// every row it had built: blank until the reader scrolled, for minutes. Uniform rows never showed
/// it. Each step here drives the app through the debug build's stress driver (`StressCommands.swift`,
/// commands appended to `SUNDOWN_STRESS_FILE`), then watches the window's pixels: neither the
/// visibility callback nor rows' reported frames can be trusted after a jump.
///
/// One launch per test, walking its steps; the tests are independent, so CI can run them apart.
final class TranscriptBlankUITests: SundownUITestCase {
    private var commands: URL!
    private var sent = 0

    // MARK: Tests

    /// Opens at its end with rows drawn: the first scroll there went to the estimated end.
    @MainActor
    func testLaunchDrawsRows() throws {
        try launchVaried()
        assertNeverBlank("just opened")
    }

    /// Another chat opened while this one was scrolled up into an older page.
    @MainActor
    func testOpeningAChatWhileScrolledUp() throws {
        try launchVaried()
        inBackground()
        run("scroll top", "wait 1500", "scroll frac 0.5", "wait 800", "chat 1")
        assertNeverBlank("another chat opened")
    }

    /// The transcript read again while scrolled deep into older pages (a replay gap's reload, a
    /// chat resumed): its rows are replaced under the reader.
    @MainActor
    func testReloadWhileScrolledUp() throws {
        try launchVaried()
        loadOlderPages(2)
        inBackground()
        run("scroll frac 0.5", "wait 800", "reload")
        assertNeverBlank("read again while scrolled up")
    }

    /// Jump to Latest from deep in the history.
    @MainActor
    func testGoingToTheEndFromDeep() throws {
        try launchVaried()
        loadOlderPages(2)
        inBackground()
        run("scroll frac 0.5", "wait 800", "scroll bottom")
        assertNeverBlank("gone to the end from deep in the history")
    }

    /// Back on the Chat tab from Tasks with older pages loaded: the transcript is made again.
    @MainActor
    func testBackFromTasks() throws {
        try launchVaried()
        loadOlderPages(2)
        inBackground()
        run("scroll frac 0.5", "wait 800", "tab tasks", "wait 800", "tab chat")
        assertNeverBlank("back from Tasks")
    }

    /// A streamed reply keeps the end in view: Jump to Latest is never offered while it streams.
    @MainActor
    func testStreamingFollowsTheEnd() throws {
        try launchVaried()
        run("send go")
        let jump = app.buttons["Jump to Latest"]
        XCTAssertFalse(waitUntil(10) { jump.exists && jump.isHittable },
                       "a streamed reply ran past the end: Jump to Latest was offered at the end")
    }

    /// Scrolling to the top keeps the reader where the page met what was held: most of the way down
    /// once a page of 500 items is above the last 50. Lost, they stayed at the top, and the top
    /// loaded page after page.
    @MainActor
    func testOlderPageKeepsThePlace() throws {
        try launchVaried()
        run("scroll top", "wait 2500")
        let bar = app.scrollViews["Transcript"].scrollBars.element(boundBy: 0)
        let place = try XCTUnwrap((bar.value as? NSNumber)?.doubleValue, "no scroll bar value")
        XCTAssertGreaterThan(place, 0.5, "the reader lost their place as an older page went in: the scroll bar is at \(place)")
    }

    // MARK: Driving

    /// The long fixture chat, its replies' heights varied as real ones are, drawn at its end.
    @MainActor
    private func launchVaried() throws {
        commands = FileManager.default.temporaryDirectory.appending(path: "sundown-stress-\(UUID().uuidString).txt")
        try Data().write(to: commands)
        launch("performance", environment: [
            "SUNDOWN_PERF_TURNS": "300", "SUNDOWN_PERF_VARIED": "1", "SUNDOWN_STRESS_FILE": commands.path,
        ])
        XCTAssertTrue(waitUntil(15) { app.scrollViews["Transcript"].exists }, "no transcript")
        _ = waitUntil(5) { (ink() ?? 0) > 0.02 }
    }

    /// Puts another app in front, as when the reader is elsewhere while the chat changes: every
    /// blank seen by hand came with Sundown in the background.
    @MainActor
    private func inBackground() {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        _ = waitUntil(5) { app.state == .runningBackground }
    }

    /// Scrolls to the top `count` times, a page going in each time.
    @MainActor
    private func loadOlderPages(_ count: Int) {
        for _ in 0..<count { run("scroll top", "wait 1500") }
    }

    /// Appends `lines` to the driver's file and waits until it has run them.
    @MainActor
    private func run(_ lines: String..., timeout: TimeInterval = 30) {
        guard let handle = try? FileHandle(forWritingTo: commands) else { return XCTFail("no stress file") }
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? handle.close()
        sent += lines.count
        let done = commands.path + ".done"
        let ran = waitUntil(timeout) {
            (try? String(contentsOfFile: done, encoding: .utf8)).flatMap { Int($0) }.map { $0 >= sent } ?? false
        }
        XCTAssertTrue(ran, "the driver didn't run \(lines)")
    }

    // MARK: Pixels

    /// Watches the window for `seconds`: a blank (the transcript's area all background) lasting
    /// more than a moment fails, with the frame attached.
    @MainActor
    private func assertNeverBlank(_ step: String, seconds: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        var blankSince: Date?
        var longest: TimeInterval = 0
        var evidence: XCUIScreenshot?
        repeat {
            let shot = mainWindow().screenshot()
            if let ink = ink(of: shot.image), ink < 0.0002 {
                let since = blankSince ?? Date()
                blankSince = since
                if Date().timeIntervalSince(since) > longest {
                    longest = Date().timeIntervalSince(since)
                    evidence = shot
                }
            } else {
                blankSince = nil
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        if longest > 0.8, let evidence {
            let attachment = XCTAttachment(screenshot: evidence)
            attachment.name = "Blank: \(step)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertLessThanOrEqual(longest, 0.8, "the transcript was blank for \(String(format: "%.1f", longest)) s: \(step)",
                                 file: file, line: line)
    }

    @MainActor
    private func ink() -> Double? { ink(of: mainWindow().screenshot().image) }

    /// The share of sampled pixels in the transcript's area (the window's right two thirds, between
    /// the toolbar and the composer) that differ from the background beside it.
    private func ink(of image: NSImage) -> Double? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let bg = rep.colorAt(x: w * 95 / 100, y: h / 2)?.usingColorSpace(.deviceRGB) else { return nil }
        var inked = 0, total = 0
        for y in stride(from: h * 12 / 100, to: h * 80 / 100, by: 5) {
            for x in stride(from: w * 32 / 100, to: w * 90 / 100, by: 5) {
                total += 1
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let d = abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent)
                if d > 0.12 { inked += 1 }
            }
        }
        return total > 0 ? Double(inked) / Double(total) : nil
    }
}
