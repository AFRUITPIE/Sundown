import Foundation
import Testing
@testable import SundownKit

/// One short command run to its end, to `done`, or to its timeout (`ShellRun`).
@Suite
struct ShellRunTests {
    /// What it printed on each stream, and how it exited; its input is empty.
    @Test func gathersOutputAndStatus() async {
        let result = await ShellRun(executable: "/bin/sh", arguments: ["-c", "cat; echo out; echo err >&2; exit 3"])
            .result(timeout: .seconds(10)) { _ in false }
        #expect(result.status == 3)
        #expect(result.output == "out\n")
        #expect(result.errors == "err\n")
    }

    /// The environment is the one given, and only that.
    @Test func runsWithTheEnvironmentGiven() async {
        let result = await ShellRun(executable: "/usr/bin/env", arguments: [], environment: ["SUNDOWN_TEST": "1"])
            .result(timeout: .seconds(10)) { _ in false }
        #expect(result.status == 0)
        #expect(result.output == "SUNDOWN_TEST=1\n")
    }

    /// `done` ends it at once, though a child it started still holds its output open; it is
    /// stopped, so it has no status.
    @Test func doneEndsItThoughAChildHoldsItsOutput() async {
        let started = ContinuousClock.now
        let result = await ShellRun(executable: "/bin/sh", arguments: ["-c", "echo MARK; sleep 30 & wait"])
            .result(timeout: .seconds(20)) { $0.contains("MARK") }
        #expect(result.output == "MARK\n")
        #expect(result.status == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A shell that exits while its child still holds the output is done when it exits.
    @Test func endsWhenItExitsThoughAChildHoldsItsOutput() async {
        let started = ContinuousClock.now
        let result = await ShellRun(executable: "/bin/sh", arguments: ["-c", "echo hi; sleep 30 & exit 0"])
            .result(timeout: .seconds(20)) { _ in false }
        #expect(result.output == "hi\n")
        #expect(result.status == 0)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// At the timeout it's stopped, keeping what it said by then.
    @Test func stopsAtTheTimeout() async {
        let started = ContinuousClock.now
        let result = await ShellRun(executable: "/bin/sh", arguments: ["-c", "echo early; exec sleep 30"])
            .result(timeout: .milliseconds(500)) { _ in false }
        #expect(result.status == nil)
        #expect(result.output == "early\n")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// One that closes its output and goes on running is stopped at the timeout too.
    @Test func stopsAtTheTimeoutWithItsOutputClosed() async {
        let started = ContinuousClock.now
        let result = await ShellRun(executable: "/bin/sh", arguments: ["-c", "exec >&- 2>&-; sleep 30"])
            .result(timeout: .milliseconds(500)) { _ in false }
        #expect(result.status == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A command that can't start has no status and said nothing; nothing is thrown.
    @Test func aMissingExecutableHasNoStatus() async {
        let result = await ShellRun(executable: "/nonexistent/sundown-test", arguments: [])
            .result(timeout: .seconds(10)) { _ in false }
        #expect(result.status == nil)
        #expect(result.output.isEmpty)
        #expect(result.errors.isEmpty)
    }

    /// Output past the limits is read and let go, so the command isn't left blocked writing it.
    @Test func capsWhatItKeeps() async {
        let result = await ShellRun(executable: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero; head -c 200000 /dev/zero >&2"])
            .result(timeout: .seconds(10)) { _ in false }
        #expect(result.status == 0)
        #expect(result.output.utf8.count >= 1_000_000 && result.output.utf8.count < 1_200_000)
        #expect(result.errors.utf8.count >= 64_000 && result.errors.utf8.count < 200_000)
    }
}
