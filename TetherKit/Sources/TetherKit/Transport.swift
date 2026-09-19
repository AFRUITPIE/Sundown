import Foundation

/// A bidirectional line-oriented byte channel to a Tether server.
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
    private var stdoutBuffer = Data()
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
                self.stdoutBuffer.append(chunk)
                while let nl = self.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = self.stdoutBuffer[self.stdoutBuffer.startIndex..<nl]
                    let data = Data(line)
                    self.stdoutBuffer.removeSubrange(self.stdoutBuffer.startIndex...nl)
                    if !data.isEmpty { continuation.yield(data) }
                }
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
