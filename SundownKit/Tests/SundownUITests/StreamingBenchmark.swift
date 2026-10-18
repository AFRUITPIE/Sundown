#if DEBUG
import Foundation
@testable import SundownFixtures
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

    /// The same reply as a turn of the chat's own, running from its prompt to its end, routed as
    /// the app routes a host's batches (`HostConnection.route`): the running turn's rows fold live
    /// at each call that starts and finishes, and its last turn folds again when it ends.
    @MainActor
    func testRoutingALiveTurnIntoALongTranscript() throws {
        try Bench.skipUnlessEnabled()
        let lines = try Self.liveTurn.map { try JSONEncoder().encode(["method": .string($0.method), "params": $0.params] as JSONValue) }
        measure(metrics: Bench.metrics, options: Bench.manually) {
            let connection = HostConnection(host: HostConfig(name: "bench", kind: .local))
            let replay = Replay(connection.thread("perf"))
            let client = RPCClient(transport: Lines(lines))
            let done = expectation(description: "replayed")
            startMeasuring()
            Task { @MainActor in
                await client.start()
                for await batch in client.notifications {
                    connection.route(batch)
                    replay.read()
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
            stopMeasuring()
            XCTAssertEqual(replay.thread.status, .idle)
        }
    }

    fileprivate static let reply = PerformanceTranscript.reply(threadID: "perf", firstSeq: 2, turn: 1)
        .map { (method: $0.0, params: $0.1) }

    /// The reply inside a turn: the chat running, the turn started, the prompt, the reply, the turn
    /// completed and the chat idle again.
    fileprivate static let liveTurn: [(method: String, params: JSONValue)] = {
        let turn = Turn(id: "perf-turn", status: .inProgress, startedAt: 1_800_000_000_000)
        let prompt = Item.userMessage(.init(id: "perf-live-prompt", createdAt: 1_799_999_999_000,
                                            content: [.text(.init(text: "Tighten the renderer once more."))]))
        let body = PerformanceTranscript.reply(threadID: "perf", firstSeq: 5, turn: 1).map { (method: $0.0, params: $0.1) }
        var seq = 5 + body.count
        func next() -> Int { seq += 1; return seq - 1 }
        var done = turn
        done.status = .completed
        let start: [(method: String, params: JSONValue)] = [
            ("thread/status/changed", json(ThreadStatusChangedNotification(threadId: "perf", seq: 2, status: .running))),
            ("turn/started", json(TurnStartedNotification(threadId: "perf", seq: 3, turn: turn))),
            ("item/started", json(ItemStartedNotification(threadId: "perf", seq: 4, item: prompt))),
        ]
        let end: [(method: String, params: JSONValue)] = [
            ("turn/completed", json(TurnCompletedNotification(threadId: "perf", seq: next(), turn: done))),
            ("thread/status/changed", json(ThreadStatusChangedNotification(threadId: "perf", seq: next(), status: .idle))),
        ]
        return start + body + end
    }()
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
    let thread: ThreadModel
    /// The streaming reply's text, built as `MarkdownView` builds its tail.
    var markdown = MarkdownStream()
    let text = NSMutableAttributedString()
    let theme = MarkdownTheme.standard
    var fading = Duration.zero

    init(_ thread: ThreadModel = ThreadModel(id: "perf")) {
        self.thread = thread
        thread.loadHistory(items: PerformanceTranscript.history, turns: [], seq: 1)
    }

    func frame(_ n: ServerNotification) {
        thread.apply(n)
        read()
    }

    /// What a frame reads once its notifications are in.
    func read() {
        _ = thread.rows(.summarized)
        if case .agentMessage(let m) = thread.box(for: thread.items.last!).item {
            let clock = ContinuousClock(), start = clock.now
            _ = markdown.update(text, to: m.text, theme: theme, streaming: true)
            fading += clock.now - start
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
