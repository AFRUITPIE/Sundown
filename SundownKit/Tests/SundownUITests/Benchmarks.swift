#if DEBUG
import AppKit
import Foundation
import SwiftUI
import TetherProtocol
import XCTest
@testable import SundownKit
@testable import SundownUI

/// Micro-benchmarks for the work the transcript and the Changes pane do outside SwiftUI, under
/// XCTest's clock, CPU (instructions retired and cycles too, steadier than time) and memory metrics,
/// five runs each. A debug build's numbers say little, so they're skipped unless asked for:
///
///     SUNDOWN_BENCH=1 swift test -c release -Xswiftc -DDEBUG -Xswiftc -enable-testing --package-path SundownKit --filter Benchmark
///
/// Compare a change's numbers with its parent's on the same Mac; there are no stored baselines.
enum Bench {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SUNDOWN_BENCH"] == "1" }

    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(enabled, "A benchmark: SUNDOWN_BENCH=1 runs it.")
    }

    /// The whole process's CPU: under `swift test`, `limitingToCurrentThread` reports nothing (and
    /// throws with a manual start), and the benchmarks have the process to themselves.
    static var metrics: [any XCTMetric] {
        [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]
    }

    /// For a block that sets up before `startMeasuring()`.
    static var manually: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    /// A chat of about a thousand items, shaped like the performance scenario's: a prompt, a burst
    /// of tool calls with a line in the middle (now and then one failed), and a Markdown answer.
    static let longChat: [Item] = (0..<52).flatMap { turn -> [Item] in
        let t = 1_700_000_000_000.0 + Double(turn * 1000)
        var items: [Item] = [.userMessage(.init(id: "bench-user-\(turn)", createdAt: t,
                                                content: [.text(.init(text: "Step \(turn): look at the next part of the renderer."))]))]
        for n in 0..<16 {
            items.append(PerformanceTranscript.toolCall(id: "bench-tool-\(turn)-\(n)", at: t + Double(n + 1), index: turn + n,
                                                        status: (turn + n) % 23 == 5 ? .failed : .completed))
            if n == 7 {
                items.append(.agentMessage(.init(id: "bench-note-\(turn)", createdAt: t + 9,
                                                 text: "Found it in `Markdown.swift`. Checking the callers next.")))
            }
        }
        items.append(.agentMessage(.init(id: "bench-answer-\(turn)", createdAt: t + 500, text: PerformanceTranscript.markdown(section: turn))))
        return items
    }

    /// A working tree's diff: 40 files of 300 changed lines, one past the 5,000 lines a file keeps,
    /// and one whose added lines run past the 1,000 characters a line keeps.
    static let largeDiff: String = (0..<40).map { file in
        let count = file == 0 ? 6_000 : 300
        let lines = (0..<count).map { n in
            switch n % 3 {
            case 0: " let kept\(n) = \(n)"
            case 1: "-let old\(n) = \(n)"
            default: "+let new\(n) = \(n)" + (file == 1 ? String(repeating: "x", count: 1_200) : "")
            }
        }
        let old = lines.count { !$0.hasPrefix("+") }, new = lines.count { !$0.hasPrefix("-") }
        return """
        diff --git a/Sources/File\(file).swift b/Sources/File\(file).swift
        --- a/Sources/File\(file).swift
        +++ b/Sources/File\(file).swift
        @@ -1,\(old) +1,\(new) @@ struct File\(file)
        \(lines.joined(separator: "\n"))
        """
    }.joined(separator: "\n")
}

final class TranscriptBenchmark: XCTestCase {
    /// A long chat's rows, from scratch, each way Settings ▸ Advanced ▸ Tool Calls folds them, as
    /// opening it (or its first delta after a reload) does.
    @MainActor
    func testRowsOfAThousandItemChat() throws {
        try Bench.skipUnlessEnabled()
        measure(metrics: Bench.metrics, options: Bench.manually) {
            let thread = ThreadModel(id: "bench")
            thread.loadHistory(items: Bench.longChat, turns: [], seq: 1)
            startMeasuring()
            for folding in [TranscriptFolding.summarized, .workedFor, .everyCall] { _ = thread.rows(folding) }
            stopMeasuring()
        }
    }

    /// Find in Chat over every row of that chat: a word on most of them, a file name on some, and
    /// something on none.
    @MainActor
    func testFindInAThousandItemChat() throws {
        try Bench.skipUnlessEnabled()
        let thread = ThreadModel(id: "bench")
        thread.loadHistory(items: Bench.longChat, turns: [], seq: 1)
        let rows = thread.rows(.everyCall)
        measure(metrics: Bench.metrics) {
            let find = TranscriptFind()
            for query in ["renderer", "ThreadModel.swift", "zzz no such text"] {
                find.query = query
                find.update(rows: rows)
            }
        }
    }

    /// Every reply of the performance scenario's chat parsed whole, as a chat opening does for the
    /// replies it shows.
    @MainActor
    func testParsingMarkdown() throws {
        try Bench.skipUnlessEnabled()
        let replies = PerformanceTranscript.history.compactMap { item -> String? in
            if case .agentMessage(let m) = item { m.text } else { nil }
        }
        measure(metrics: Bench.metrics) {
            for reply in replies { _ = MarkdownView.parse(reply) }
        }
    }
}

final class MarkdownBenchmark: XCTestCase {
    /// The performance scenario's replies as one long reply, laid out at a new width each time, as a
    /// live resize does; selectable, as the transcript's text is.
    @MainActor
    func testResizingAReply() throws {
        try Bench.skipUnlessEnabled()
        let text = PerformanceTranscript.history.compactMap { item -> String? in
            if case .agentMessage(let m) = item { m.text } else { nil }
        }.joined(separator: "\n\n")
        let host = NSHostingView(rootView: MarkdownView(text: text).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = []
        let widths = Array(stride(from: 420.0, through: 1100, by: 10))
        func layout(_ width: Double) {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 50_000)
            host.layoutSubtreeIfNeeded()
        }
        for width in widths.prefix(5) { layout(width) }
        var pass = 0.0
        measure(metrics: Bench.metrics) {
            // A fraction of a point off each time, so no width repeats: text caches its layout per width.
            pass += 0.37
            for width in widths { layout(width + pass) }
        }
    }
}

final class DiffBenchmark: XCTestCase {
    /// The Changes pane's parse of a large working tree, which runs off the main actor but decides
    /// how soon the pane fills.
    func testParsingALargeDiff() throws {
        try Bench.skipUnlessEnabled()
        let diff = Bench.largeDiff
        XCTAssertEqual(UnifiedDiff.parse(diff).count, 40)
        measure(metrics: Bench.metrics) {
            _ = UnifiedDiff.parse(diff)
        }
    }
}
#endif
