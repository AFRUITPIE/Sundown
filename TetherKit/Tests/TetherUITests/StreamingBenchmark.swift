#if DEBUG
import Foundation
import TetherProtocol
import XCTest
@testable import TetherKit
@testable import TetherUI

/// The per-frame work a streamed reply costs outside SwiftUI's own diffing and layout: applying the
/// frame's delta to the model, the rows the transcript reads, and the Markdown the growing reply
/// parses to. Replays the performance scenario (TETHER_UI_TEST_SCENARIO=performance) without a UI.
///
///     TETHER_BENCH=1 swift test -c release -Xswiftc -DDEBUG -Xswiftc -enable-testing --package-path TetherKit --filter Benchmark
final class StreamingBenchmark: XCTestCase {
    /// Each frame's own work, timed one by one: a frame at 120 Hz is 8.3 ms and SwiftUI needs most of
    /// it, so this should be a sliver. Quick; runs in every `swift test`.
    @MainActor
    func testEachFrameIsASliver() throws {
        let notifications = try Self.reply.map { try ServerNotification(method: $0.method, params: JSONEncoder().encode($0.params)) }
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
        print(String(format: "StreamingBenchmark: %d frames, total %.1f ms (fade %.1f ms), p50 %.3f ms, p95 %.3f ms, worst %.3f ms",
                     ms.count, total, milliseconds(replay.fading), p50, p95, worst))
        XCTAssertLessThan(p95, 2)
    }

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

    private static let reply = PerformanceTranscript.reply(threadID: "perf", firstSeq: 2, turn: 1)
        .map { (method: $0.0, params: $0.1) }
}

/// The long chat, and what the transcript and its streaming row read once per frame.
@MainActor
private final class Replay {
    let thread = ThreadModel(id: "perf")
    let markdown = MarkdownCache()
    /// The streaming block's fade, made again for each new block as `ArrivingText` is.
    var arrivals = Arrivals()
    var arrivalsBlock = ""
    var now = Date.timeIntervalSinceReferenceDate
    var fading = Duration.zero

    init() {
        thread.loadHistory(items: PerformanceTranscript.history, turns: [], seq: 1)
    }

    func frame(_ n: ServerNotification) {
        thread.apply(n)
        _ = thread.rows
        if case .agentMessage(let m) = thread.box(for: thread.items.last!).item {
            let blocks = markdown.blocks(for: m.text)
            if let text = blocks.last?.inline.first {
                let clock = ContinuousClock(), fadeStart = clock.now
                let block = "\(m.id)-\(blocks.count)"
                if block != arrivalsBlock { arrivals = Arrivals(); arrivalsBlock = block }
                _ = arrivals.text(for: text, at: now, arrives: true)
                fading += clock.now - fadeStart
            }
        }
        now += 1.0 / 60
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
