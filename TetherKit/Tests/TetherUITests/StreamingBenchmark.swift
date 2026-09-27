#if DEBUG
import Foundation
import Testing
import TetherProtocol
@testable import TetherKit
@testable import TetherUI

/// The per-frame work a streamed reply costs outside SwiftUI's own diffing and layout: applying the
/// frame's delta to the model, the rows the transcript reads, and the Markdown the growing reply
/// parses to. Replays the performance scenario (TETHER_UI_TEST_SCENARIO=performance) without a UI.
///
///     swift test -c release -Xswiftc -DDEBUG -Xswiftc -enable-testing --package-path TetherKit --filter StreamingBenchmark
@MainActor
@Suite
struct StreamingBenchmark {
    @Test func streamingALongReplyIntoALongTranscript() throws {
        let thread = ThreadModel(id: "perf")
        thread.loadHistory(items: PerformanceTranscript.history, turns: [], seq: 1)
        let notifications = try PerformanceTranscript.reply(threadID: "perf", firstSeq: 2, turn: 1).map { name, params in
            try ServerNotification(method: name, params: JSONEncoder().encode(params))
        }
        let markdown = MarkdownCache()
        // The streaming block's fade, made again for each new block as `ArrivingText` is.
        var arrivals = Arrivals()
        var arrivalsBlock = ""
        var now = Date.timeIntervalSinceReferenceDate
        var fading = Duration.zero
        var frames: [Duration] = []
        let clock = ContinuousClock()

        for n in notifications {
            let start = clock.now
            thread.apply(n)
            // What the transcript and the streaming row read once per frame.
            _ = thread.rows
            if case .agentMessage(let m) = thread.box(for: thread.items.last!).item {
                let blocks = markdown.blocks(for: m.text)
                if let text = blocks.last?.inline.first {
                    let fadeStart = clock.now
                    let block = "\(m.id)-\(blocks.count)"
                    if block != arrivalsBlock { arrivals = Arrivals(); arrivalsBlock = block }
                    _ = arrivals.text(for: text, at: now, arrives: true)
                    fading += clock.now - fadeStart
                }
            }
            frames.append(clock.now - start)
            now += 1.0 / 60
        }

        func milliseconds(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        let ms = frames.map(milliseconds).sorted()
        let total = ms.reduce(0, +)
        let p50 = ms[ms.count / 2], p95 = ms[ms.count * 95 / 100], worst = ms.last ?? 0
        print(String(format: "StreamingBenchmark: %d frames, total %.1f ms (fade %.1f ms), p50 %.3f ms, p95 %.3f ms, worst %.3f ms",
                     ms.count, total, milliseconds(fading), p50, p95, worst))
        // A frame at 120 Hz is 8.3 ms, and SwiftUI needs most of it; this work should be a sliver.
        #expect(p95 < 2)
    }
}
#endif
