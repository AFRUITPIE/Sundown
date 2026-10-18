#if DEBUG
import AppKit
import OSLog
import SwiftUI
import SundownKit

/// The transcript's latest scroll geometry, for the driver's `scroll frac`, fed by `TranscriptView`
/// only while the driver runs.
@MainActor enum StressState {
    static var content: CGFloat = 0
    static var container: CGFloat = 0
}

extension Notification.Name {
    /// A scroll the driver asks of the transcript: userInfo "y" (an absolute offset) or "edge"
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
                let f = CGFloat(Double(args.dropFirst().first ?? "0") ?? 0)
                post(["y": f * max(0, StressState.content - StressState.container)])
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
        case "wait": try? await Task.sleep(for: .milliseconds(Int(arg) ?? 100))
        default: break
        }
    }

    private func post(_ info: [String: Any]) {
        NotificationCenter.default.post(name: .stressScroll, object: nil, userInfo: info)
    }
}
#endif
