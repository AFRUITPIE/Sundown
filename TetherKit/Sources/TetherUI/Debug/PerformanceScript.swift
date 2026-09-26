#if DEBUG
import AppKit
import os
import SwiftUI
import TetherKit

/// A fixed sequence of the interactions whose frame rate matters: the inspector and sidebar opening
/// and closing, inspector tabs, switching chats, New Chat, and window resizes. Run with
/// TETHER_UI_TEST_MODE=1 TETHER_UI_TEST_SCENARIO=performance TETHER_PERF_SCRIPT=1 while recording
/// the Animation Hitches template; every step is a Points of Interest signpost, so a hitch lines up
/// with the step that caused it.
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

    private static func step(_ name: StaticString, _ action: () async -> Void) async {
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
        while clock.now - began < .seconds(1.5) {
            let t = Double((clock.now - began).components.attoseconds) / 1e18 + Double((clock.now - began).components.seconds)
            var frame = start
            frame.size.width = start.width - 300 * sin(t / 1.5 * .pi)
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .milliseconds(8))
        }
        window.setFrame(start, display: true)
    }
}
#endif
