#if DEBUG
import OSLog
import SwiftUI
import SundownKit

/// Debug builds' Stress menu: what the host can do to the chat on screen on its own (reload after a
/// replay gap, trim, unload), on demand, for hunting transcript bugs.
public struct StressCommands: View {
    @FocusedValue(\.window) private var window

    public init() {}

    public var body: some View {
        let thread = window?.selectedThread
        let connection = window?.connection
        Group {
            Button("Reload Chat (Replay Gap)") {
                if let thread, let connection { Task { await connection.stressReload(thread) } }
            }
            .keyboardShortcut("1", modifiers: [.control, .option])
            Button("Trim Chat to Last Page") {
                if let thread, let connection { connection.stressTrim(thread) }
            }
            .keyboardShortcut("2", modifiers: [.control, .option])
            Button("Unload and Reopen Chat") {
                if let thread, let connection { Task { await connection.stressUnloadAndReopen(thread) } }
            }
            .keyboardShortcut("3", modifiers: [.control, .option])
            Button("Flash an Open Error") {
                if let thread, let connection { Task { await connection.stressErrorFlash(thread) } }
            }
            .keyboardShortcut("4", modifiers: [.control, .option])
        }
        .disabled(thread == nil || connection == nil)
    }
}

/// The transcript's latest scroll geometry, for the driver's relative scrolls.
@MainActor enum StressState {
    static var offset: CGFloat = 0
    static var content: CGFloat = 0
    static var container: CGFloat = 0
}

extension Notification.Name {
    /// A scroll the driver asks of the transcript: userInfo "y" (an absolute offset) or "edge"
    /// ("top" or "bottom").
    static let stressScroll = Notification.Name("SundownStressScroll")
}

/// Runs commands appended to the file named by SUNDOWN_STRESS_FILE, one per line, in the first
/// window, so a scenario needs no mouse or keyboard: each one is logged under ScrollTrace as
/// `STRESS <command>`, between the transcript's own events. Commands:
///   scroll top | bottom | frac <0…1> | by <points>
///   reload | trim | unload | error          (the host doing it to the chat on screen)
///   send <text> | stop
///   fold summarized | workedFor | everyCall
///   chat <index in the sidebar's list> | chat next
///   tab chat | tasks | diff
///   reconnect | wait <ms> | mark <words>
struct StressDriver: ViewModifier {
    let window: WindowModel
    private static let log = Logger(subsystem: "com.haydenhong.Sundown", category: "ScrollTrace")
    static let path = ProcessInfo.processInfo.environment["SUNDOWN_STRESS_FILE"]
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
        let arg = words.dropFirst().joined(separator: " ")
        let thread = window.selectedThread
        let connection = window.connection
        switch verb {
        case "scroll":
            let parts = arg.split(separator: " ")
            switch parts.first {
            case "top", "bottom", "edgebottom", "lastrow": post(["edge": String(parts[0])])
            case "frac":
                let f = CGFloat(Double(parts.dropFirst().first ?? "0") ?? 0)
                post(["y": f * max(0, StressState.content - StressState.container)])
            case "by":
                let d = CGFloat(Double(parts.dropFirst().first ?? "0") ?? 0)
                post(["y": StressState.offset + d])
            default: break
            }
        case "reload": if let thread, let connection { await connection.stressReload(thread) }
        case "trim": if let thread, let connection { connection.stressTrim(thread) }
        case "unload": if let thread, let connection { await connection.stressUnloadAndReopen(thread) }
        case "error": if let thread, let connection { await connection.stressErrorFlash(thread) }
        case "send":
            // As the composer's Send does: to the end, then the prompt.
            post(["edge": "bottom"])
            if let thread, let connection { Task { await connection.send(thread, input: [.text(.init(text: arg.isEmpty ? "go" : arg))]) } }
        case "stop": if let thread, let connection { Task { await connection.interrupt(thread) } }
        case "fold":
            if let display = Appearance.ToolCallDisplay(rawValue: arg) { window.app.appearance.toolCalls = display }
        case "chat":
            guard let chats = connection?.chats, !chats.isEmpty else { return }
            if arg == "next" {
                let i = chats.firstIndex { $0.id == thread?.id } ?? -1
                window.open(threadID: chats[(i + 1) % chats.count].id)
            } else if let i = Int(arg), chats.indices.contains(i) {
                window.open(threadID: chats[i].id)
            }
        case "tab":
            switch arg {
            case "tasks": window.tab = .tasks
            case "diff": window.tab = .diff
            default: window.tab = .chat
            }
        case "reconnect": if let connection { Task { await connection.reconnect() } }
        case "snap": BlankSampler.snapshot()
        case "wait": try? await Task.sleep(for: .milliseconds(Int(arg) ?? 100))
        default: break
        }
    }

    private func post(_ info: [String: Any]) {
        NotificationCenter.default.post(name: .stressScroll, object: nil, userInfo: info)
    }
}
#endif
