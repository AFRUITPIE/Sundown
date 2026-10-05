import Foundation

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

/// Runs a command (local shell or `ssh`) and speaks JSONL over its stdin/stdout.
public final class ProcessTransport: Transport, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var stderrBuffer = Data()
    /// Only touched from stdout's readabilityHandler, which the system serializes.
    private var stdoutLines = LineSplitter()
    private var started = false
    public let commandDescription: String

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        commandDescription = ([executable] + arguments).joined(separator: " ")
    }

    public var stderrText: String {
        lock.withLock { String(decoding: stderrBuffer, as: UTF8.self) }
    }

    public func lines() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.withLock {
                    self.stderrBuffer.append(d)
                    if self.stderrBuffer.count > 256_000 { self.stderrBuffer.removeFirst(self.stderrBuffer.count - 128_000) }
                }
            }
            stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard let self, !chunk.isEmpty else {
                    h.readabilityHandler = nil
                    return
                }
                self.stdoutLines.split(chunk) { continuation.yield($0) }
            }
            process.terminationHandler = { [weak self] p in
                self?.stdout.fileHandleForReading.readabilityHandler = nil
                self?.stderr.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: TransportError.closed(exitCode: p.terminationStatus, stderr: self?.stderrText ?? ""))
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                if self.process.isRunning { self.process.terminate() }
            }
            do {
                try process.run()
                lock.withLock { started = true }
            } catch {
                continuation.finish(throwing: TransportError.launchFailed(error.localizedDescription))
            }
        }
    }

    public func send(_ line: Data) async throws {
        var data = line
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// Splits a byte stream into its newline-terminated lines. Each byte is looked at once, as its chunk
/// arrives. A line that spans chunks is gathered in a buffer of its own and handed over in it, which
/// isn't then kept: one long line doesn't leave its size allocated for the connection's life.
struct LineSplitter {
    /// The start of a line whose newline hasn't come yet. Never holds a newline.
    private(set) var partial = Data()

    /// Calls `line` with each complete, non-empty line the chunk ends, in order.
    mutating func split(_ chunk: Data, _ line: (Data) -> Void) {
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
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
}
