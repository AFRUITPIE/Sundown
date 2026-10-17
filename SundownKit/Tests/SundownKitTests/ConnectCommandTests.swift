import Foundation
import Testing
@testable import SundownKit

@Suite
struct ConnectCommandTests {
    /// npx under the login shell, pinned to the app's version; a Server Command is run as it is.
    @Test func connectRunsTheServerWithNpx() {
        let boot = HostBootstrapper()
        let npx = "npx --yes tether-server@\(ServerRelease.version) connect"
        #expect(boot.connectCommand(for: .local).arguments == ["-lc", "exec \(npx)"])
        let ssh = boot.connectCommand(for: HostConfig(name: "box", kind: .ssh(destination: "box")))
        #expect(ssh.executable == "/usr/bin/ssh")
        #expect(ssh.arguments.suffix(2) == ["box", "exec \"$SHELL\" -lc 'exec \(npx)'"])
        var custom = HostConfig.local
        custom.serverCommand = "bun run ../tether-server/src/cli.ts connect"
        #expect(boot.connectCommand(for: custom).arguments.last == "bun run ../tether-server/src/cli.ts connect")
    }

    /// The interactive shell's PATH goes to `npx` through `env`, which every shell runs alike; one
    /// that double quotes would change is left out.
    @Test func connectGivesNpxTheShellsPath() {
        let boot = HostBootstrapper()
        let npx = "npx --yes tether-server@\(ServerRelease.version) connect"
        #expect(boot.connectCommand(for: .local, path: "/opt/bin:/usr/bin").arguments == ["-lc", "exec env PATH=\"/opt/bin:/usr/bin\" \(npx)"])
        let ssh = boot.connectCommand(for: HostConfig(name: "box", kind: .ssh(destination: "box")), path: "~/.local/bin:/usr/bin")
        #expect(ssh.arguments.last == "exec \"$SHELL\" -lc 'exec env PATH=\"~/.local/bin:/usr/bin\" \(npx)'")
        #expect(boot.connectCommand(for: .local, path: "/a$b:/usr/bin").arguments == ["-lc", "exec \(npx)"])
        #expect(boot.connectCommand(for: .local, path: "/it's:/usr/bin").arguments == ["-lc", "exec \(npx)"])
    }

    /// Whatever the rc files print around it, the PATH is what's between the markers.
    @Test func shellPathIsBetweenTheMarkers() {
        let m = HostBootstrapper.pathMarker
        #expect(HostBootstrapper.shellPath(in: "Welcome!\n\(m)/a:/b\n\(m)bye") == "/a:/b")
        #expect(HostBootstrapper.shellPath(in: "\(m)/a:/b\n") == nil)
        #expect(HostBootstrapper.shellPath(in: "\(m)\n\(m)") == nil)
        let ssh = HostBootstrapper().shellPathCommand(for: HostConfig(name: "box", kind: .ssh(destination: "box")))
        #expect(ssh.arguments.last == "exec \"$SHELL\" -ilc 'printf %s \(m); printenv PATH; echo \(m)'")
    }

    /// A shell that doesn't say its PATH in time leaves the login shell's: the probe gives up at its
    /// timeout with no PATH, rather than an error or a wait for the shell (#73).
    @Test func thePathProbeGivesUpAtItsTimeout() async throws {
        let started = ContinuousClock.now
        let path = try await HostBootstrapper().interactivePath(for: .local, timeout: .milliseconds(1))
        #expect(path == nil, "the probe waited for the shell, which said \(path ?? "")")
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// `ssh` that can't reach the host (exit 255) is an error at once, not a PATH or a wait (#73).
    @Test func thePathProbeThrowsWhenSSHCantReachTheHost() async {
        let started = ContinuousClock.now
        let host = HostConfig(name: "Gone", kind: .ssh(destination: "sundown-probe-test.invalid"))
        await #expect(throws: TransportError.self, "an unreachable host read as having no PATH") {
            _ = try await HostBootstrapper().interactivePath(for: host, timeout: .seconds(10))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A Claude Code session's variables stay out of the server's environment; the rest go through.
    @Test func serverEnvironmentLeavesOutAClaudeSessions() {
        let env = HostBootstrapper.serverEnvironment([
            "PATH": "/usr/bin", "HOME": "/Users/me", "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_EFFORT": "high",
        ])
        #expect(env == ["PATH": "/usr/bin", "HOME": "/Users/me"])
    }

    /// The pinned package from npm, run the way a host runs it. Opt in (`SUNDOWN_NPX_E2E=1`), once
    /// that version is published.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUNDOWN_NPX_E2E"] == "1"))
    func npxRunsThePinnedPackage() throws {
        let process = Process()
        process.executableURL = URL(filePath: HostBootstrapper.loginShell)
        process.arguments = ["-lc", "npx --yes tether-server@\(ServerRelease.version) version --json"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("\"version\":\"\(ServerRelease.version)\""))
    }
}
