import Foundation
import Testing
@testable import SundownKit

/// A real process spoken to over its stdin and stdout (`ProcessTransport`).
@Suite
struct ProcessTransportTests {
    private static func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }

    /// Each line sent comes back through `lines()`, in the order it was sent.
    @Test func echoesLinesInOrder() async throws {
        let transport = ProcessTransport(executable: "/bin/cat", arguments: [])
        var lines = transport.lines().makeAsyncIterator()
        for n in 0..<200 { try await transport.send(Data("line \(n)".utf8)) }
        for n in 0..<200 {
            let line = try await lines.next()
            #expect(line.map(Self.text) == "line \(n)")
        }
        await transport.close()
    }

    /// A burst far larger than a pipe's buffer, in lines of every size, arrives whole and in order,
    /// whatever chunks it was read in.
    @Test func aLargeBurstArrivesWhole() async throws {
        let sizes = (0..<400).map { ($0 * 7919) % 20_000 + 1 }
        let script = sizes.enumerated().map { "printf '%s\\n' \"$(head -c \($1) /dev/zero | tr '\\0' '\($0 % 10)')\"" }
            .joined(separator: "; ")
        let transport = ProcessTransport(executable: "/bin/sh", arguments: ["-c", script])
        var received: [Data] = []
        do {
            for try await line in transport.lines() { received.append(line) }
        } catch TransportError.closed(let code, _) {
            #expect(code == 0)
        }
        #expect(received.count == sizes.count)
        for (index, line) in received.enumerated() {
            #expect(line.count == sizes[index])
            #expect(line.allSatisfy { $0 == UInt8(ascii: "0") + UInt8(index % 10) })
        }
    }

    /// On exit the stream ends with the exit status and what it wrote on stderr.
    @Test func exitEndsTheStreamWithItsStatusAndStderr() async throws {
        let transport = ProcessTransport(executable: "/bin/sh", arguments: ["-c", "echo '{}'; echo oops >&2; exit 7"])
        var lines: [String] = []
        do {
            for try await line in transport.lines() { lines.append(Self.text(line)) }
            Issue.record("the stream ended without an error")
        } catch TransportError.closed(let code, let stderr) {
            #expect(code == 7)
            #expect(stderr == "oops\n")
        }
        #expect(lines == ["{}"])
        await #expect(throws: (any Error).self, "a line sent once it had gone") {
            try await transport.send(Data("late".utf8))
        }
    }

    /// The environment given is the process's whole environment.
    @Test func runsWithTheEnvironmentGiven() async throws {
        let transport = ProcessTransport(executable: "/usr/bin/env", arguments: [], environment: ["SUNDOWN_TEST": "1"])
        var lines: [String] = []
        do {
            for try await line in transport.lines() { lines.append(Self.text(line)) }
        } catch TransportError.closed {}
        #expect(lines == ["SUNDOWN_TEST=1"])
    }

    /// One that can't start ends the stream with `launchFailed`, and a line sent fails.
    @Test func aMissingExecutableFailsToLaunch() async {
        let transport = ProcessTransport(executable: "/nonexistent/sundown-test", arguments: [])
        do {
            for try await _ in transport.lines() {}
            Issue.record("the stream ended without an error")
        } catch {
            guard case .launchFailed? = error as? TransportError else {
                Issue.record("ended with \(error)")
                return
            }
        }
        await #expect(throws: (any Error).self) { try await transport.send(Data("x".utf8)) }
    }

    /// `close()` closes stdin and stops the process, though it would have run on.
    @Test func closeStopsIt() async throws {
        let started = ContinuousClock.now
        let transport = ProcessTransport(executable: "/bin/sh", arguments: ["-c", "echo ready; exec sleep 30"])
        var lines = transport.lines().makeAsyncIterator()
        #expect(try await lines.next().map(Self.text) == "ready")
        await transport.close()
        do {
            while try await lines.next() != nil {}
            Issue.record("the stream ended without an error")
        } catch TransportError.closed(let code, _) {
            #expect(code == SIGTERM)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// `close()` closes stdin first: `cat` sees the end of its input and exits by itself.
    @Test func closeEndsItsInput() async throws {
        let transport = ProcessTransport(executable: "/bin/cat", arguments: [])
        var lines = transport.lines().makeAsyncIterator()
        try await transport.send(Data("hi".utf8))
        #expect(try await lines.next().map(Self.text) == "hi")
        await transport.close()
        do {
            while try await lines.next() != nil {}
        } catch TransportError.closed {}
        await #expect(throws: (any Error).self) { try await transport.send(Data("x".utf8)) }
    }

    /// It ends when the process exits, though a child it started still holds stdout open, with
    /// every line it wrote.
    @Test func exitEndsItThoughAChildHoldsStdout() async throws {
        let started = ContinuousClock.now
        let transport = ProcessTransport(executable: "/bin/sh", arguments: ["-c", "echo one; echo two; sleep 30 & exit 4"])
        var lines: [String] = []
        do {
            for try await line in transport.lines() { lines.append(Self.text(line)) }
        } catch TransportError.closed(let code, _) {
            #expect(code == 4)
        }
        #expect(lines == ["one", "two"])
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// One that closes both its outputs can say nothing more: it's stopped, and the stream ends.
    @Test func closingBothOutputsEndsIt() async throws {
        let started = ContinuousClock.now
        let transport = ProcessTransport(executable: "/bin/sh", arguments: ["-c", "exec >&- 2>&-; exec sleep 30"])
        do {
            for try await _ in transport.lines() {}
            Issue.record("the stream ended without an error")
        } catch TransportError.closed(let code, _) {
            #expect(code == SIGTERM)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// A reader that stops reading stops the process.
    @Test func cancellingTheReaderStopsIt() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("sundown-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // Says when it's been stopped: the trap writes the file, then the shell exits.
        let transport = ProcessTransport(executable: "/bin/sh", arguments: [
            "-c", "trap 'echo stopped > \"\(marker.path)\"; exit 0' TERM; echo ready; while :; do sleep 0.05; done",
        ])
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let reader = Task {
            for try await line in transport.lines() where Self.text(line) == "ready" { readyContinuation.yield() }
        }
        for await _ in ready { break }
        reader.cancel()
        _ = await reader.result
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path), "the process wasn't asked to stop")
    }

    /// Writing as the process goes doesn't crash the app (SIGPIPE), and once it has gone a send fails.
    @Test func sendingToAProcessThatHasGoneFails() async throws {
        let transport = ProcessTransport(executable: "/bin/sh", arguments: ["-c", "exec 0<&-; echo bye"])
        let stream = transport.lines()
        for _ in 0..<200 { try? await transport.send(Data(repeating: 0x41, count: 4096)) }
        do {
            for try await _ in stream {}
        } catch TransportError.closed(let code, _) {
            #expect(code == 0)
        }
        await #expect(throws: (any Error).self) { try await transport.send(Data("x".utf8)) }
    }
}
