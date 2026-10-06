#if DEBUG
import Foundation
import Testing
import TetherProtocol
import XCTest
@testable import SundownKit
@testable import SundownUI

/// The per-frame work a streamed reply costs outside SwiftUI's own diffing and layout: applying the
/// frame's delta to the model, the rows the transcript reads, and the Markdown the growing reply
/// parses to. Replays the performance scenario (SUNDOWN_UI_TEST_SCENARIO=performance) without a UI.
///
///     SUNDOWN_BENCH=1 swift test -c release -Xswiftc -DDEBUG -Xswiftc -enable-testing --package-path SundownKit --filter Benchmark
final class StreamingBenchmark: XCTestCase {
    /// The whole reply, each line decoded by the client as it arrives from a host, under XCTest's
    /// clock, CPU and memory metrics. The CPU includes the client's decoding, which runs on its own
    /// actor rather than the main thread.
    @MainActor
    func testReplayingALongReplyIntoALongTranscript() throws {
        try Bench.skipUnlessEnabled()
        let lines = try Self.reply.map { try JSONEncoder().encode(["method": .string($0.method), "params": $0.params] as JSONValue) }
        measure(metrics: Bench.metrics, options: Bench.manually) {
            let replay = Replay()
            let client = RPCClient(transport: Lines(lines))
            let done = expectation(description: "replayed")
            startMeasuring()
            Task { @MainActor in
                await client.start()
                // A batch is what the app applies before a frame draws.
                for await batch in client.notifications {
                    for n in batch.dropLast() { replay.thread.apply(n) }
                    if let last = batch.last { replay.frame(last) }
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
            stopMeasuring()
        }
    }

    fileprivate static let reply = PerformanceTranscript.reply(threadID: "perf", firstSeq: 2, turn: 1)
        .map { (method: $0.0, params: $0.1) }
}

/// Each frame's own work, timed one by one: a frame at 120 Hz is 8.3 ms and SwiftUI needs most of
/// it, so this should be a sliver. Quick; runs in every `swift test`.
@MainActor
@Suite
struct StreamingFrameTests {
    @Test func eachFrameIsASliver() throws {
        let notifications = try StreamingBenchmark.reply.map { try ServerNotification(method: $0.method, params: JSONEncoder().encode($0.params)) }
        let replay = Replay()
        var frames: [Duration] = []
        let clock = ContinuousClock()
        for n in notifications {
            let start = clock.now
            replay.frame(n)
            frames.append(clock.now - start)
        }
        func milliseconds(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        let ms = frames.map(milliseconds).sorted()
        let total = ms.reduce(0, +)
        let p50 = ms[ms.count / 2], p95 = ms[ms.count * 95 / 100], worst = ms.last ?? 0
        print(String(format: "StreamingBenchmark: %d frames, total %.1f ms (building text %.1f ms), p50 %.3f ms, p95 %.3f ms, worst %.3f ms",
                     ms.count, total, milliseconds(replay.fading), p50, p95, worst))
        #expect(p95 < 2)
    }
}

/// The long chat, and what the transcript and its streaming row read once per frame.
@MainActor
private final class Replay {
    let thread = ThreadModel(id: "perf")
    let markdown = MarkdownCache()
    /// Building the streaming block's text, as `MarkdownTextView` does for its changed tail.
    let theme = MarkdownTheme(style: .reply, scale: 1, increasedContrast: false)
    var fading = Duration.zero

    init() {
        thread.loadHistory(items: PerformanceTranscript.history, turns: [], seq: 1)
    }

    func frame(_ n: ServerNotification) {
        thread.apply(n)
        _ = thread.rows
        if case .agentMessage(let m) = thread.box(for: thread.items.last!).item {
            let blocks = markdown.blocks(for: m.text)
            if let last = blocks.last {
                let clock = ContinuousClock(), fadeStart = clock.now
                _ = MarkdownBuilder.build(last, leading: blocks.count > 1, spacing: 12, widestMarker: nil, theme: theme)
                fading += clock.now - fadeStart
            }
        }
    }
}

/// A host that sends every line at once, then hangs up.
private final class Lines: Transport, @unchecked Sendable {
    private let queued: [Data]
    init(_ lines: [Data]) { queued = lines }

    func lines() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            for line in queued { continuation.yield(line) }
            continuation.finish()
        }
    }

    func send(_ line: Data) async throws {}
    func close() async {}
}
#endif
