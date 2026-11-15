#if DEBUG
import AppKit
import OSLog
import SwiftUI
import SundownKit

extension Notification.Name {
    /// A scroll the driver asks of the transcript: userInfo "frac" (0 the top, 1 the end) or "edge"
    /// ("top" or "bottom").
    static let stressScroll = Notification.Name("SundownStressScroll")
}

/// For `TranscriptBlankUITests`: runs commands appended to the file named by SUNDOWN_STRESS_FILE,
/// one per line, in the first window, so a scenario needs no mouse or keyboard, and writes how many
/// have run to the file beside it (`<file>.done`). Debug builds only, and only under the UI tests'
/// fixture (SUNDOWN_UI_TEST_MODE). Each is logged as `STRESS <command>` (category Stress). Commands:
///   scroll top | bottom | frac <0…1>
///   reload                                     (as after a replay gap)
///   send <text>
///   chat <index in the sidebar's list>
///   tab chat | tasks | diff
///   snap left | right | full | center [now]    (the window tiled as ⌃⌥←, →, ↑ do; animated unless now)
///   wait <ms>
///   resize <points> <steps> [tight]            (a live resize of the window's width, a step at a time)
///   wheel <points>                             (the mouse's wheel over the transcript; positive is up)
///   fold summarized | workedFor | everyCall    (View ▸ Tool Calls)
///   prompt prev | next                         (Chat ▸ Previous and Next Prompt)
///   find <query> | findnext                    (Find in Chat)
///   probe                                      (logs the transcript's place and heights, `PROBE …`)
struct StressDriver: ViewModifier {
    let window: WindowModel
    private static let log = Logger(subsystem: "com.haydenhong.Sundown", category: "Stress")
    static let path: String? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SUNDOWN_UI_TEST_MODE"] == "1" else { return nil }
        return environment["SUNDOWN_STRESS_FILE"]
    }()
    @MainActor private static var claimed = false

    func body(content: Content) -> some View {
        content.task {
            guard let path = Self.path, !Self.claimed else { return }
            Self.claimed = true
            var done = 0
            while !Task.isCancelled {
                let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                while done < lines.count, !Task.isCancelled {
                    let line = lines[done].trimmingCharacters(in: .whitespaces)
                    done += 1
                    Self.log.error("STRESS \(line, privacy: .public)")
                    await run(line)
                    // How many commands have run, for a UI test waiting on them.
                    try? String(done).write(toFile: path + ".done", atomically: true, encoding: .utf8)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func run(_ line: String) async {
        let words = line.split(separator: " ").map(String.init)
        guard let verb = words.first else { return }
        let args = Array(words.dropFirst())
        let arg = args.joined(separator: " ")
        let thread = window.selectedThread
        let connection = window.connection
        switch verb {
        case "scroll":
            switch args.first {
            case "top", "bottom": post(["edge": args[0]])
            case "frac":
                post(["frac": CGFloat(Double(args.dropFirst().first ?? "0") ?? 0)])
            default: break
            }
        case "reload": if let thread, let connection { await connection.stressReload(thread) }
        case "send":
            // As the composer's Send does: to the end, then the prompt.
            post(["edge": "bottom"])
            if let thread, let connection { Task { await connection.send(thread, input: [.text(.init(text: arg.isEmpty ? "go" : arg))]) } }
        case "chat":
            guard let chats = connection?.chats, let i = Int(arg), chats.indices.contains(i) else { return }
            window.open(threadID: chats[i].id)
        case "tab":
            switch arg {
            case "tasks": window.tab = .tasks
            case "diff": window.tab = .diff
            default: window.tab = .chat
            }
        case "snap":
            guard let frameWindow = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let area = frameWindow.screen?.visibleFrame, let side = args.first else { return }
            let half = area.width / 2
            let frame: NSRect = switch side {
            case "left": NSRect(x: area.minX, y: area.minY, width: half, height: area.height)
            case "right": NSRect(x: area.minX + half, y: area.minY, width: half, height: area.height)
            case "center": NSRect(x: area.midX - 500, y: area.midY - 370, width: 1000, height: 740)
            default: area
            }
            frameWindow.setFrame(frame, display: true, animate: args.last != "now")
        case "resize":
            // A live resize, as dragging the window's edge makes one: the width changed a few
            // points at a time, each step laid out and drawn. `resize <points> <steps> [tight]`:
            // tight runs every step in one turn of the run loop, as AppKit's resize tracking does;
            // otherwise a frame (8 ms) between steps.
            guard let w = Self.window, args.count >= 2, let total = Double(args[0]), let steps = Int(args[1]), steps > 0 else { return }
            let tight = args.count > 2 && args[2] == "tight"
            for i in 1...steps {
                var frame = w.frame
                frame.size.width += total / Double(steps)
                w.setFrame(frame, display: true, animate: false)
                if !tight || i % 20 == 0 { try? await Task.sleep(for: .milliseconds(8)) }
                _ = i
            }
        case "wheel":
            // The reader's scroll wheel over the transcript, as a mouse's (positive is up): through
            // the window, so it's hit-tested and reaches the scroll view as a real one does. Not a
            // trackpad's phased events: a scroll view tracks those from the window server's own
            // stream, and ignores them made in-process.
            guard let w = Self.window, let total = Int32(arg) else { return }
            let steps = max(1, Int(abs(total)) / 40)
            for _ in 0..<steps {
                guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: total / Int32(steps), wheel2: 0, wheel3: 0) else { return }
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                // In-process its window is nil, so its location is taken as the window's: the
                // transcript's middle, right of the reading column's center.
                e.location = CGPoint(x: w.frame.width * 0.65, y: NSScreen.screens[0].frame.height - w.frame.height * 0.5)
                if let ns = NSEvent(cgEvent: e) { w.sendEvent(ns) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        case "fold": if let d = Appearance.ToolCallDisplay(rawValue: arg) { window.app.appearance.toolCalls = d }
        case "prompt": window.prompts.go(arg == "prev" ? .previous : .next)
        case "find": window.find.show(query: arg)
        case "findnext": window.find.next()
        case "probe":
            // The transcript's place and heights as they stand.
            Self.log.error("PROBE \(TranscriptModel.current?.probe ?? "no transcript", privacy: .public)")
        default: break
        }
    }

    @MainActor private static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }

    private func post(_ info: [String: Any]) {
        NotificationCenter.default.post(name: .stressScroll, object: nil, userInfo: info)
    }
}
#endif
