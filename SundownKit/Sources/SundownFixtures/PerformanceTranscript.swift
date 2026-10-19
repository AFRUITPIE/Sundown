import Foundation
import TetherProtocol
import SundownKit

/// A long transcript and a long streamed reply, for profiling (SUNDOWN_UI_TEST_SCENARIO=performance).
/// Synthetic but shaped like real work: prompts, folded tool calls, and Markdown replies with
/// headings, lists, inline code, code blocks and tables.
enum PerformanceTranscript {
    /// Two more long chats, for switching between chats.
    static let otherChats: [ThreadSummary] = (1...2).map {
        .init(threadId: "perf-chat-\($0)", title: "Performance chat \($0)", cwd: "/tmp/sundown-fixture",
              updatedAt: 1_700_000_000_000 - Double($0), status: .idle)
    }

    /// SUNDOWN_PERF_TURNS sizes it (30 turns by default). Each turn works the way a real one does:
    /// bursts of tool calls with a line of text between them, now and then a failed call, which stays
    /// on its own row, and a Markdown answer at the end.
    static let history: [Item] = (0..<(Int(ProcessInfo.processInfo.environment["SUNDOWN_PERF_TURNS"] ?? "") ?? 30)).flatMap { turn -> [Item] in
        let t = 1_700_000_000_000.0 + Double(turn * 1000)
        var items: [Item] = [.userMessage(.init(id: "perf-user-\(turn)", createdAt: t,
                                                content: [.text(.init(text: "Step \(turn): look at the next part of the renderer and tighten it up."))]))]
        var n = 0
        // A long current turn exposes eager layout work that the usual small turns conceal.
        let bursts = turn == 29 && ProcessInfo.processInfo.environment["SUNDOWN_PERF_LONG_TURN"] == "1" ? 80 : 3
        for burst in 0..<bursts {
            for _ in 0..<(2 + (turn + burst * 3) % 7) {
                let status: ToolStatus = turn % 4 == 1 && burst == 1 && n % 5 == 2 ? .failed : .completed
                items.append(toolCall(id: "perf-tool-\(turn)-\(n)", at: t + Double(n + 1), index: turn + n, status: status))
                n += 1
            }
            if burst < bursts - 1 {
                items.append(.agentMessage(.init(id: "perf-note-\(turn)-\(burst)", createdAt: t + Double(n + 1),
                                                 text: "Found it in `\(files[(turn + burst) % files.count])`. Checking the callers next.")))
            }
        }
        items.append(.agentMessage(.init(id: "perf-answer-\(turn)", createdAt: t + 500, text: answer(turn))))
        return items
    }

    /// SUNDOWN_PERF_VARIED=1 makes the answers' heights vary as real ones do: now and then a very
    /// long one (a dozen sections, or a 300-line code block), sometimes a single line.
    private static func answer(_ turn: Int) -> String {
        guard ProcessInfo.processInfo.environment["SUNDOWN_PERF_VARIED"] == "1" else { return markdown(section: turn) }
        switch turn % 11 {
        case 0: return (0..<12).map { markdown(section: turn * 100 + $0) }.joined(separator: "\n\n")
        case 3: return "Done."
        case 5: return "Here is the file:\n\n```swift\n" + (0..<300).map { "let value\($0) = compute(\($0)) // line \($0)" }.joined(separator: "\n") + "\n```"
        case 7: return "Short note."
        default: return markdown(section: turn)
        }
    }

    private static let files = ["Markdown.swift", "TranscriptView.swift", "ThreadModel.swift", "ItemViews.swift", "ToolCallView.swift"]

    /// One of the tools a turn uses most, with the input and output each is shown with.
    static func toolCall(id: String, at time: Double, index i: Int, status: ToolStatus) -> Item {
        let file = "SundownKit/Sources/SundownUI/\(files[i % files.count])"
        let failed = status == .failed
        switch i % 5 {
        case 0:
            return .toolCall(.init(id: id, createdAt: time, name: "Bash", kind: .bash,
                                   input: ["command": .string("rg -n 'MarkdownView' SundownKit/Sources | head -\(i % 9 + 3)")],
                                   status: status, outputText: failed ? "rg: SundownKit/Sources/Missing: No such file or directory" : "\(file):\(i % 90 + 5): struct MarkdownView: View {",
                                   isError: failed ? true : nil))
        case 1:
            return .toolCall(.init(id: id, createdAt: time, name: "Read", kind: .fileRead, input: ["file_path": .string(file)],
                                   status: status, outputText: (0..<12).map { "\($0 + 1)\timport SwiftUI // line \($0)" }.joined(separator: "\n")))
        case 2:
            return .toolCall(.init(id: id, createdAt: time, name: "Grep", kind: .grep,
                                   input: ["pattern": .string("readingColumn"), "path": .string("SundownKit/Sources")],
                                   status: status, outputText: files.map { "SundownKit/Sources/SundownUI/\($0)" }.joined(separator: "\n")))
        case 3:
            return .toolCall(Item.ToolCall(id: id, createdAt: time, name: "Edit", kind: .fileEdit,
                                   input: ["file_path": .string(file), "old_string": .string("let blocks = parse(text)"),
                                           "new_string": .string("let blocks = cache.blocks(for: text)")],
                                   status: status, outputText: failed ? "String to replace not found in file." : "The file \(file) has been updated.",
                                   isError: failed ? true : nil).withComparedEdit)
        default:
            return .toolCall(.init(id: id, createdAt: time, name: "Glob", kind: .glob, input: ["pattern": .string("**/*View.swift")],
                                   status: status, outputText: files.map { "SundownKit/Sources/SundownUI/\($0)" }.joined(separator: "\n")))
        }
    }

    /// SUNDOWN_PERF_REPLY_SECTIONS sections (3 by default, about 3 KB and 10 s) of Markdown streamed
    /// six characters a frame, each after a burst of tool calls that start running and complete a
    /// few frames later, as a real turn's do. `turn` keeps each reply's items distinct.
    static let replySections = Int(ProcessInfo.processInfo.environment["SUNDOWN_PERF_REPLY_SECTIONS"] ?? "") ?? 3

    static func reply(threadID: String, firstSeq: Int, turn: Int) -> [(String, JSONValue)] {
        var seq = firstSeq
        var out: [(String, JSONValue)] = []
        func next() -> Int { seq += 1; return seq - 1 }
        for section in 0..<replySections {
            for call in 0..<(3 + section % 4) {
                let id = "perf-\(turn)-tool-\(section)-\(call)", time = 1_800_000_000_000.0 + Double(section * 100 + call)
                let done = toolCall(id: id, at: time, index: section * 7 + call, status: .completed)
                guard case .toolCall(var running) = done else { continue }
                running.status = .running
                running.outputText = nil
                out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item: .toolCall(running)))))
                // Blank frames: the call runs for a moment before it completes. The first runs for
                // a few seconds, long enough for a UI test to find it running.
                for _ in 0..<(section == 0 && call == 0 ? 200 : 4) { out.append(("item/toolCall/progress", json(ItemToolCallProgressNotification(
                    threadId: threadID, seq: next(), itemId: id, elapsedSeconds: 0.1)))) }
                out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item: done))))
            }
            let answerID = "perf-\(turn)-answer-\(section)"
            out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_000_000 + Double(section * 100 + 50), text: ""))))))
            var rest = Substring(markdown(section: 100 + section))
            while !rest.isEmpty {
                let chunk = rest.prefix(6)
                rest = rest.dropFirst(6)
                out.append(("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                    threadId: threadID, seq: next(), itemId: answerID, delta: String(chunk)))))
            }
            out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_000_000 + Double(section * 100 + 50),
                                    text: markdown(section: 100 + section)))))))
        }
        // SUNDOWN_PERF_LONG_REPLY=n: then one reply of n sections, as a long report is: a single
        // message thousands of points tall. Streamed faster, 60 characters a frame.
        if longReplySections > 0 {
            let answerID = "perf-\(turn)-long"
            let text = (0..<longReplySections).map { markdown(section: 200 + $0) }.joined(separator: "\n\n")
            out.append(("item/started", json(ItemStartedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_090_000, text: ""))))))
            var rest = Substring(text)
            while !rest.isEmpty {
                let chunk = rest.prefix(60)
                rest = rest.dropFirst(60)
                out.append(("item/agentMessage/delta", json(ItemAgentMessageDeltaNotification(
                    threadId: threadID, seq: next(), itemId: answerID, delta: String(chunk)))))
            }
            out.append(("item/completed", json(ItemCompletedNotification(threadId: threadID, seq: next(), item:
                .agentMessage(.init(id: answerID, createdAt: 1_800_000_090_000, text: text))))))
        }
        return out
    }

    static let longReplySections = Int(ProcessInfo.processInfo.environment["SUNDOWN_PERF_LONG_REPLY"] ?? "") ?? 0

    static func markdown(section n: Int) -> String {
        """
        ## Section \(n): tightening the renderer

        The transcript re-renders on every streamed token, so anything **proportional to its length** \
        shows up as dropped frames. Here the cost is in `MarkdownCache.blocks(for:)` and in the rows \
        that `TranscriptView` diffs — each one cheap alone, but multiplied by every token.

        - Parse only the tail that changed; the settled prefix stays as it was.
        - Keep each finished block's view equal to its last, so SwiftUI skips it.
        - Measure with signposts before and after — a guess isn't a result.

        ```swift
        func blocks(for text: String) -> [Block] {
            if text == last { return cached }
            let tail = text.dropFirst(settled.utf8.count)
            return settledBlocks + parse(tail)
        }
        ```

        | Step | Before | After |
        |------|--------|-------|
        | Parse | \(n % 7 + 3) ms | 0.\(n % 9) ms |
        | Rows | \(n % 5 + 2) ms | 0.1 ms |

        > Streaming should cost what the new characters cost, not what the whole message costs.
        """
    }
}
