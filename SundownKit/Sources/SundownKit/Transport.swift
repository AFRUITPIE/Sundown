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

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not start server: \(m)"
        case .closed(let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "Server connection closed (exit \(code))" + (tail.isEmpty ? "" : ":\n\(tail)")
        }
    }
}

/// Runs a command (local shell or `ssh`), from when it's made, and speaks JSONL over its stdin and
/// stdout. Subprocess's handles on a process are good only inside its `run`, so a task holds that
/// for the process's life; cancelled, Subprocess stops the process.
public final class ProcessTransport: Transport {
    private let output: AsyncThrowingStream<Data, any Error>
    private let stdin = Pipe()
    private let task: Task<Void, Never>

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        var options = PlatformOptions()
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(2))]
        let custom = environment.map { Dictionary(uniqueKeysWithValues: $0.map { (Environment.Key(rawValue: $0)!, $1) }) }
        let configuration = Configuration(executable: .path(FilePath(executable)), arguments: Arguments(arguments),
                                          environment: custom.map(Environment.custom) ?? .inherit, platformOptions: options)
        let (output, lines) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (stdin, stdout) = (stdin, Pipe())
        // Once the process has gone, a write fails rather than raising SIGPIPE, which would end the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        task = Task {
            do {
                let (childIn, childOut) = (FileDescriptor(rawValue: stdin.fileHandleForReading.fileDescriptor),
                                           FileDescriptor(rawValue: stdout.fileHandleForWriting.fileDescriptor))
                let result = try await run(configuration, input: .fileDescriptor(childIn, closeAfterSpawningProcess: false),
                                           output: .fileDescriptor(childOut, closeAfterSpawningProcess: false),
                                           error: .sequence) { execution in
                    // The child's ends, now its own.
                    try? stdin.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    // Its last 128,000 to 256,000 bytes.
                    async let errors = (try? await execution.standardError.reduce(into: Data()) { data, chunk in
                        chunk.withUnsafeBytes { data.append(contentsOf: $0) }
                        if data.count > 256_000 { data.removeFirst(data.count - 128_000) }
                    }) ?? Data()
                    await Self.readLines(from: stdout.fileHandleForReading, of: execution.processIdentifier.value, into: lines)
                    // Both outputs have closed: it has exited, or can say nothing more and is stopped.
                    let stderr = await errors
                    await execution.teardown(using: configuration.platformOptions.teardownSequence)
                    return stderr
                }
                let code = switch result.terminationStatus { case .exited(let code), .signaled(let code): code }
                lines.finish(throwing: TransportError.closed(exitCode: code, stderr: String(decoding: result.closureResult, as: UTF8.self)))
            } catch {
                try? stdin.fileHandleForWriting.close()
                lines.finish(throwing: TransportError.launchFailed(String(describing: error)))
            }
        }
        self.output = output
        // The reader has stopped reading.
        lines.onTermination = { [task] _ in task.cancel() }
    }

    /// Ends with `TransportError.closed` when it exits, or `.launchFailed`. Stopping reading stops it.
    public func lines() -> AsyncThrowingStream<Data, any Error> { output }

    public func send(_ line: Data) async throws {
        try stdin.fileHandleForWriting.write(contentsOf: line + [0x0A])
    }

    /// Closes its stdin, leaving it running.
    func endInput() {
        try? stdin.fileHandleForWriting.close()
    }

    /// Closes its stdin and stops it: SIGTERM, then SIGKILL 2 s later.
    public func close() async {
        endInput()
        task.cancel()
    }

    /// Stdout's lines as they come, until it closes or the process exits (a child may hold it open),
    /// with what was in the pipe then. A dispatch source reads into one buffer and splits on its queue:
    /// Subprocess's `.sequence` made a stream and a zeroed buffer per read and woke a task for each.
    private static func readLines(from handle: FileHandle, of pid: pid_t,
                                  into lines: AsyncThrowingStream<Data, any Error>.Continuation) async {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let queue = DispatchQueue(label: "com.haydenhong.Sundown.transport")
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let reading = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            // Told even of one that had exited before it was made, which isn't reaped until this returns.
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 1)
            var splitter = LineSplitter()
            /// Reads all there is now; false once nothing more ever will be.
            func drain() -> Bool {
                var count: Int
                repeat {
                    count = read(fd, buffer.baseAddress, buffer.count)
                    if count > 0 { splitter.split(UnsafeRawBufferPointer(rebasing: buffer[..<count])) { lines.yield($0) } }
                } while count > 0 || (count < 0 && errno == EINTR)
                return count < 0 && errno == EAGAIN
            }
            reading.setEventHandler { if !drain() { reading.cancel() } }
            exit.setEventHandler { _ = drain(); reading.cancel() }
            reading.setCancelHandler {
                // A last line without its newline.
                if !splitter.partial.isEmpty { lines.yield(splitter.partial) }
                exit.cancel()
                buffer.deallocate()
                try? handle.close()
                finished.resume()
            }
            reading.activate()
            exit.activate()
        }
    }
}

/// Splits a byte stream into its newline-terminated lines. Each byte is looked at once, as its chunk
/// arrives. A line that spans chunks is gathered in a buffer of its own and handed over in it, which
/// isn't then kept: one long line doesn't leave its size allocated for the connection's life.
struct LineSplitter {
    /// The start of a line whose newline hasn't come yet. Never holds a newline.
    private(set) var partial = Data()

    /// Calls `line` with each complete, non-empty line the chunk ends, in order.
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
