#if DEBUG
import AppKit
import os
import SwiftUI
import TetherKit

/// A fixed sequence of the interactions whose frame rate matters: the inspector and sidebar opening
/// and closing, inspector tabs, switching chats, New Chat, and window resizes. Run with
/// TETHER_UI_TEST_MODE=1 TETHER_UI_TEST_SCENARIO=performance TETHER_PERF_SCRIPT=1 while recording
/// the Animation Hitches template; every step is a Points of Interest signpost, so a hitch lines up
/// with the step that caused it. Pass `-NSAppSleepDisabled YES` when the window may be hidden or the
/// screen locked: App Nap otherwise throttles the app about 25 s in and every later step looks slower.
@MainActor
enum PerformanceScript {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["TETHER_PERF_SCRIPT"] == "1" }
    private static let signposter = OSSignposter(subsystem: "com.haydenhong.Tether", category: .pointsOfInterest)
    /// Each step's name and wall-clock start, written to TETHER_PERF_LOG for lining up with a trace.
    private static var log: [[String: Any]] = []

    static func run(_ app: AppModel) async {
        // After the performance scenario's streamed reply, which ends about 17 s in.
        try? await Task.sleep(for: .seconds(20))
        let loops = Int(ProcessInfo.processInfo.environment["TETHER_PERF_LOOPS"] ?? "") ?? 2
        for _ in 0..<loops {
            await step("inspector open") { app.showInspector = true }
            await step("tab session") { app.inspectorPane = .session }
            await step("tab mcp") { app.inspectorPane = .mcp }
            await step("tab tasks") { app.inspectorPane = .tasks }
            await step("inspector close") { app.showInspector = false }
            await step("sidebar hide") { toggleSidebar() }
            await step("sidebar show") { toggleSidebar() }
            await step("chat 1") { app.open(threadID: "perf-chat-1") }
            await step("chat 2") { app.open(threadID: "perf-chat-2") }
            await step("new chat") { app.newChat() }
            await step("chat fixture") { app.open(threadID: UITestFixture.threadID) }
            await step("resize animated") { await animatedResize() }
            await step("resize live") { await liveResize() }
        }
        NSLog("PERF done")
    }

    /// TETHER_PERF_STEPS, comma-separated, limits the run to steps whose names start with one of them.
    private static let only = ProcessInfo.processInfo.environment["TETHER_PERF_STEPS"]?
        .split(separator: ",").map(String.init).nilIfEmpty

    private static func step(_ name: StaticString, _ action: () async -> Void) async {
        if let only, !only.contains(where: { "\(name)".hasPrefix($0) }) { return }
        let state = signposter.beginInterval(name)
        NSLog("PERF %@", "\(name)")
        log.append(["step": "\(name)", "time": Date().timeIntervalSince1970])
        if let path = ProcessInfo.processInfo.environment["TETHER_PERF_LOG"],
           let data = try? JSONSerialization.data(withJSONObject: log) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        await action()
        try? await Task.sleep(for: .seconds(1.2))
        signposter.endInterval(name, state)
    }

    private static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }

    private static func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    /// AppKit's own frame animation, narrower then back.
    private static func animatedResize() async {
        guard let window else { return }
        let start = window.frame
        var narrow = start
        narrow.size.width = max(760, start.width - 320)
        window.setFrame(narrow, display: true, animate: true)
        try? await Task.sleep(for: .seconds(0.6))
        window.setFrame(start, display: true, animate: true)
    }

    /// A drag-like resize: a new width every 8 ms for 1.5 s, as the mouse would deliver it.
    private static func liveResize() async {
        guard let window else { return }
        let start = window.frame
        let clock = ContinuousClock(), began = clock.now
        var durations: [Duration] = []
        while clock.now - began < .seconds(1.5) {
            let t = Double((clock.now - began).components.attoseconds) / 1e18 + Double((clock.now - began).components.seconds)
            var frame = start
            frame.size.width = start.width - 300 * sin(t / 1.5 * .pi)
            let before = clock.now
            window.setFrame(frame, display: true)
            durations.append(clock.now - before)
            try? await Task.sleep(for: .milliseconds(8))
        }
        window.setFrame(start, display: true)
        record(durations, as: "resize live frames")
    }

    /// How long each synchronous layout and display took: the frame time the step costs, which the
    /// time profile alone can't give while the loop keeps the main thread busy.
    private static func record(_ values: [Duration], as name: String) {
        let ms = values.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }.sorted()
        guard !ms.isEmpty else { return }
        func pct(_ p: Double) -> Double { ms[min(ms.count - 1, Int(Double(ms.count) * p))] }
        NSLog("PERF %@: n %d p50 %.2f p95 %.2f max %.2f ms", name, ms.count, pct(0.5), pct(0.95), ms.last!)
        log.append(["step": name, "time": Date().timeIntervalSince1970, "n": ms.count,
                    "p50": pct(0.5), "p95": pct(0.95), "max": ms.last!])
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
#endif
