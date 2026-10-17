import Foundation
import Subprocess
import System

/// A bidirectional line-oriented byte channel to a Sundown server.
public protocol Transport: Sendable {
    /// Newline-delimited JSON messages from the server. Finishes when the channel closes.
    func lines() -> AsyncThrowingStream<Data, any Error>
    func send(_ line: Data) async throws
    func close() async
}

public enum TransportError: LocalizedError {
    case launchFailed(String)
    case closed(exitCode: Int32, stderr: String)
    /// A line sent once the server had gone, or as it went.
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not start server: \(m)"
        case .closed(let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "Server connection closed (exit \(code))" + (tail.isEmpty ? "" : ":\n\(tail)")
        case .notRunning: return "The server isn't running."
        }
    }
}

/// Runs a command (local shell or `ssh`) and speaks JSONL over its stdin/stdout.
///
/// Subprocess's handles on the process are good only inside its `run`, so one task holds that for
/// the connection's life: `lines()` lets it start, `send` hands it lines to write, and `close()` or
/// the reader going away asks it to stop the process. Each is a stream into the task, so nothing
/// here is shared or locked.
public final class ProcessTransport: Transport {
    private let output: AsyncThrowingStream<Data, any Error>
    private let start: AsyncStream<Void>.Continuation
    private let outgoing: AsyncStream<Outgoing>.Continuation
    private let stop: AsyncStream<Void>.Continuation
    private let stderr = StderrBuffer()

    /// A line to write, and its sender, told once it's written.
    private struct Outgoing: Sendable {
        let line: Data
        let sent: CheckedContinuation<Void, any Error>
    }

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        _ = Self.ignoreBrokenPipes
        var options = PlatformOptions()
        // Asked to stop, then made to.
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(2))]
        let configuration = Configuration(executable: .path(FilePath(executable)), arguments: Arguments(arguments),
                                          environment: environment.map(Environment.exactly) ?? .inherit,
                                          platformOptions: options)
        let (output, lines) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (starts, start) = AsyncStream<Void>.makeStream()
        let (toWrite, outgoing) = AsyncStream<Outgoing>.makeStream()
        let (stops, stop) = AsyncStream<Void>.makeStream()
        (self.output, self.start, self.outgoing, self.stop) = (output, start, outgoing, stop)
        // The reader has stopped reading.
        lines.onTermination = { _ in stop.yield() }
        let stderr = self.stderr
        Task {
            var writing = false
            var started = starts.makeAsyncIterator()
            if await started.next() != nil {
                do {
                    let result = try await run(configuration, input: .inputWriter, output: .sequence, error: .sequence) { execution in
                        writing = true
                        await withDiscardingTaskGroup { group in
                            group.addTask {
                                for await item in toWrite {
                                    do {
                                        let written = try await execution.standardInputWriter.write(item.line)
                                        guard written == item.line.count else { throw TransportError.notRunning }
                                        item.sent.resume()
                                    } catch {
                                        item.sent.resume(throwing: error)
                                    }
                                }
                                try? await execution.standardInputWriter.finish()
                            }
                            group.addTask {
                                for await _ in stops {
                                    await execution.teardown(using: configuration.platformOptions.teardownSequence)
                                    break
                                }
                            }
                            async let errors: Void = stderr.read(execution.standardError)
                            var splitter = LineSplitter()
                            do {
                                for try await chunk in execution.standardOutput {
                                    chunk.withUnsafeBytes { splitter.split($0) { lines.yield($0) } }
                                }
                            } catch {}
                            // Nothing more is written.
                            outgoing.finish()
                            // Both outputs have closed: it has exited (Subprocess ends a read when it
                            // does, though a child may hold the pipe), or it can say nothing more and
                            // is stopped, since `close()` no longer could.
                            await errors
                            stop.yield()
                            stop.finish()
                        }
                    }
                    lines.finish(throwing: TransportError.closed(exitCode: result.terminationStatus.code, stderr: await stderr.text))
                } catch {
                    lines.finish(throwing: TransportError.launchFailed(String(describing: error)))
                }
            }
            outgoing.finish()
            stop.finish()
            lines.finish()
            // Lines sent to a process that never started.
            if !writing {
                for await item in toWrite { item.sent.resume(throwing: TransportError.notRunning) }
            }
        }
    }

    deinit {
        start.finish()
        // As a pipe let go of would: the server sees the end of its input.
        outgoing.finish()
    }

    /// Writing to a pipe whose reader has gone raises SIGPIPE, which would end the app. Foundation's
    /// pipes are made not to (`F_SETNOSIGPIPE`); Subprocess's aren't, and their descriptors aren't
    /// ours to set, so the signal is ignored, as Subprocess's own tests do. The write then fails
    /// with EPIPE, and Subprocess resets every signal to its default for the processes it starts.
    private static let ignoreBrokenPipes: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    /// The end of what the server wrote on stderr.
    public var stderrText: String {
        get async { await stderr.text }
    }

    /// Starts the process. Lines are its stdout's; the stream ends when it exits, with
    /// `TransportError.closed`, or when it can't start, with `.launchFailed`. Stopping reading stops it.
    public func lines() -> AsyncThrowingStream<Data, any Error> {
        start.yield()
        start.finish()
        return output
    }

    public func send(_ line: Data) async throws {
        var data = line
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
            if case .terminated = outgoing.yield(Outgoing(line: data, sent: sent)) {
                sent.resume(throwing: TransportError.notRunning)
            }
        }
    }

    /// Closes the server's stdin and stops it.
    public func close() async {
        start.finish()
        outgoing.finish()
        stop.yield()
    }
}

/// What a server wrote on stderr, its last 128,000 to 256,000 bytes.
private actor StderrBuffer {
    private var data = Data()

    /// Keeps what the stream says until it ends.
    nonisolated func read(_ stream: SubprocessOutputSequence) async {
        do {
            for try await chunk in stream { await append(chunk) }
        } catch {}
    }

    private func append(_ chunk: SubprocessOutputSequence.Buffer) {
        chunk.withUnsafeBytes { data.append($0.assumingMemoryBound(to: UInt8.self)) }
        if data.count > 256_000 { data.removeFirst(data.count - 128_000) }
    }

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Splits a byte stream into its newline-terminated lines. Each byte is looked at once, as its chunk
/// arrives. A line that spans chunks is gathered in a buffer of its own and handed over in it, which
/// isn't then kept: one long line doesn't leave its size allocated for the connection's life.
struct LineSplitter {
    /// The start of a line whose newline hasn't come yet. Never holds a newline.
    private(set) var partial = Data()

    /// Calls `line` with each complete, non-empty line the chunk ends, in order.
    mutating func split(_ chunk: Data, _ line: (Data) -> Void) {
        chunk.withUnsafeBytes { split($0, line) }
    }

    mutating func split(_ bytes: UnsafeRawBufferPointer, _ line: (Data) -> Void) {
        guard let base = bytes.baseAddress else { return }
        var start = 0
        while start < bytes.count, let found = memchr(base + start, 0x0A, bytes.count - start) {
            let end = base.distance(to: UnsafeRawPointer(found))
            if partial.isEmpty {
                if end > start { line(Data(bytes: base + start, count: end - start)) }
            } else {
                partial.append(base.assumingMemoryBound(to: UInt8.self) + start, count: end - start)
                line(partial)
                partial = Data()
            }
            start = end + 1
        }
        if start < bytes.count {
            partial.append(base.assumingMemoryBound(to: UInt8.self) + start, count: bytes.count - start)
        }
    }
}
