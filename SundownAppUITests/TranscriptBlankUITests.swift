import AppKit
import XCTest

/// The transcript never goes blank, and stays at its end or the reader's place (2026-10-09).
///
/// With replies from a line to thousands of points tall (`SUNDOWN_PERF_VARIED`), the lazy stack's
/// estimate of the rows it hasn't built is far off, and a scroll to an estimated place left it past
/// every row it had built: blank until the reader scrolled, for minutes. Uniform rows never showed
/// it. Each step here drives the app through the debug build's stress driver (`StressDriver.swift`,
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

    /// Back on the Chat tab from Tasks, a reader who had scrolled up is where they were, not at the
    /// end: the transcript is made again, at its end, as it comes back.
    @MainActor
    func testBackFromTasksKeepsThePlace() throws {
        try launchVaried()
        for depth in 1...3 {
            scrollUp(by: 1500 * depth)
            let place = settledPlace()
            run("tab tasks", "wait 800", "tab chat")
            assertNeverBlank("back from Tasks, \(depth)")
            assertKept(place, "back from Tasks, \(depth)")
        }
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

    /// The window tiled back and forth (⌃⌥←, → and ↑), animated and at once, at the end and scrolled
    /// up: every change of width lays every row out again, and rapid ones left the lazy stack's
    /// built rows outside the window, or none built at all (2026-10-13), until the reader scrolled.
    /// At the end the reader stays there; scrolled up, the message at the top stays on screen
    /// through an animated snap, as ⌃⌥← and → do it. Not through one at once (setFrame without
    /// animation): the row the transcript goes back to is the topmost the visibility callback last
    /// listed, which after a jump of the whole width could be rows at the end (2026-10-17).
    @MainActor
    func testSnapping() throws {
        try launchVaried()
        let jump = app.buttons["Jump to Latest"]
        func snapAround(atEnd: Bool) {
            let where_ = atEnd ? "at the end" : "scrolled up"
            for round in 1...6 {
                let animated = !round.isMultiple(of: 2)
                let now = animated ? "" : " now"
                for side in ["left", "right", "full"] {
                    if !atEnd, !jump.exists { scrollUp(by: 3000) }
                    let place = !atEnd && animated ? settledPlace() : nil
                    let step = "snapped \(side)\(now), round \(round), \(where_)"
                    run("snap \(side)\(now)")
                    assertNeverBlank(step, seconds: 1.5)
                    if let place { assertKept(place, step) }
                    if atEnd { XCTAssertFalse(jump.exists && jump.isHittable, "left the end: \(step)") }
                }
            }
            // Several at once, with nothing between them.
            run("snap left now", "snap right now", "snap full now", "snap left now", "snap full now")
            assertNeverBlank("snapped in a burst, \(where_)")
            if atEnd { XCTAssertFalse(jump.exists && jump.isHittable, "left the end: snapped in a burst") }
            // After a burst, what the window reports of its frame (and so where XCUITest points and
            // what it reads) lagged what was on screen for seconds: settled before going on.
            run("snap center now", "wait 1000")
        }
        snapAround(atEnd: true)
        snapAround(atEnd: false)
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

    /// Scrolls up by `points` as the reader does, with the scroll wheel over the transcript, and
    /// waits until Jump to Latest says they're away from the end. (`scroll frac` goes to an offset
    /// worked out from the lazy stack's estimate of the content's height, and could land past every
    /// row, where the transcript went back to the end.)
    @MainActor
    private func scrollUp(by points: Int) {
        let transcript = mainWindow().coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        for _ in 0..<max(1, points / 1500) {
            transcript.scroll(byDeltaX: 0, deltaY: CGFloat(min(points, 1500)))
            Thread.sleep(forTimeInterval: 0.3)
        }
        if !app.buttons["Jump to Latest"].appears(timeout: 5) {
            let shot = XCTAttachment(screenshot: mainWindow().screenshot())
            shot.name = "Still at the end after scrolling up by \(points)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("scrolling up by \(points) left the reader at the end: \(messagesOnScreen())")
        }
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

    // MARK: Place

    /// The messages in the transcript's visible part, top to bottom, by their first words: what the
    /// reader is looking at. Read from one snapshot of the window.
    @MainActor
    private func messagesOnScreen() -> [String] {
        let scrollView = app.scrollViews["Transcript"]
        // A snapshot can fail while the app is busy laying out: tried again.
        var root: (any XCUIElementSnapshot)?
        for _ in 0..<3 where root == nil {
            do { root = try scrollView.snapshot() } catch {
                snapshotError = "\(error)"
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        guard let root else { return [] }
        var messages: [(frame: CGRect, words: String)] = []
        func walk(_ element: any XCUIElementSnapshot) {
            if let words = element.messageWords, !words.isEmpty, element.frame.height > 0 {
                messages.append((element.frame, String(words.prefix(60))))
            }
            element.children.forEach(walk)
        }
        walk(root)
        let frame = root.frame
        // Below the toolbar, above the bottom bar.
        let visible = CGRect(x: frame.minX, y: frame.minY + 60, width: frame.width, height: max(0, frame.height - 180))
        return messages.filter { $0.frame.intersects(visible) }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.words)
    }

    /// Why the last snapshot of the transcript failed, for a failure's message.
    private var snapshotError = ""

    /// Where the reader is once scrolling has settled: the messages on screen, read until two reads
    /// half a second apart agree.
    @MainActor
    private func settledPlace() -> [String] {
        var last = messagesOnScreen()
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            let now = messagesOnScreen()
            if now == last, !now.isEmpty { return now }
            last = now
        }
        return last
    }

    /// The reader is still where `place` was: its topmost prompt or numbered reply (words no other
    /// message has), else its topmost message, is still on screen.
    @MainActor
    private func assertKept(_ place: [String], _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let top = place.first(where: { $0.hasPrefix("Step ") || $0.contains("Section ") }) ?? place.first else {
            let shot = XCTAttachment(screenshot: mainWindow().screenshot())
            shot.name = "No message: \(step)"
            shot.lifetime = .keepAlways
            add(shot)
            return XCTFail("no message on screen before: \(step) (ink \(ink() ?? -1), \(snapshotError))", file: file, line: line)
        }
        let now = settledPlace()
        XCTAssertTrue(now.contains(top), "lost the reader's place: \(step): \(top) was on screen, now \(now)", file: file, line: line)
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
            let window = mainWindow()
            let shot = window.screenshot()
            if let ink = ink(of: shot.image, window: window.frame), ink < 0.0002 {
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
    private func ink() -> Double? {
        let window = mainWindow()
        return ink(of: window.screenshot().image, window: window.frame)
    }

    /// The share of sampled pixels in the transcript's visible part (its scroll view, below the
    /// toolbar, above the bottom bar, clear of the scroller) that differ from its most common color,
    /// its background. From the scroll view's own frame, whatever the window's width and the
    /// sidebar's: at half a screen's width a share of the window took in the sidebar, and a blank
    /// read as drawn.
    @MainActor
    private func ink(of image: NSImage, window: CGRect) -> Double? {
        let transcript = app.scrollViews["Transcript"].frame
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              window.width > 0, !transcript.isEmpty else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let scale = CGFloat(w) / window.width
        let area = CGRect(x: transcript.minX - window.minX, y: transcript.minY - window.minY + 60,
                          width: transcript.width - 20, height: transcript.height - 60 - 150)
            .intersection(CGRect(origin: .zero, size: window.size))
        guard area.width > 40, area.height > 40 else { return nil }
        // The buffer's rows run from the image's top, as the frames' y does.
        var samples: [UInt32] = []
        for y in stride(from: Int(area.minY * scale), to: min(h, Int(area.maxY * scale)), by: 5) {
            for x in stride(from: Int(area.minX * scale), to: min(w, Int(area.maxX * scale)), by: 5) {
                let i = (y * w + x) * 4
                samples.append(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
            }
        }
        guard !samples.isEmpty else { return nil }
        func channels(_ c: UInt32) -> (Int, Int, Int) { (Int(c >> 16 & 0xff), Int(c >> 8 & 0xff), Int(c & 0xff)) }
        // The background: the most common color, to within a few levels.
        var counts: [UInt32: Int] = [:]
        for c in samples { counts[c & 0xf0f0f0, default: 0] += 1 }
        guard let mode = counts.max(by: { $0.value < $1.value })?.key,
              let bg = samples.first(where: { $0 & 0xf0f0f0 == mode }).map(channels) else { return nil }
        let inked = samples.filter { c in
            let (r, g, b) = channels(c)
            return abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2) > 30
        }.count
        return Double(inked) / Double(samples.count)
    }
}
