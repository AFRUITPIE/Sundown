import Foundation
import Testing
@testable import TetherKit

@Suite
struct ConnectCommandTests {
    /// npx under the login shell, pinned to the app's version; a Server Command is run as it is.
    @Test func connectRunsTheServerWithNpx() {
        let boot = HostBootstrapper()
        let npx = "npx --yes --prefer-offline tether-server@\(ServerRelease.version) connect"
        #expect(boot.connectCommand(for: .local).arguments == ["-lc", "exec \(npx)"])
        let ssh = boot.connectCommand(for: HostConfig(name: "box", kind: .ssh(destination: "box")))
        #expect(ssh.executable == "/usr/bin/ssh")
        #expect(ssh.arguments.suffix(2) == ["box", "exec \"$SHELL\" -lc 'exec \(npx)'"])
        var custom = HostConfig.local
        custom.serverCommand = "bun run ../tether-server/src/cli.ts connect"
        #expect(boot.connectCommand(for: custom).arguments.last == "bun run ../tether-server/src/cli.ts connect")
    }

    /// The pinned package from npm, run the way a host runs it. Opt in (`TETHER_NPX_E2E=1`), once
    /// that version is published.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TETHER_NPX_E2E"] == "1"))
    func npxRunsThePinnedPackage() throws {
        let process = Process()
        process.executableURL = URL(filePath: HostBootstrapper.loginShell)
        process.arguments = ["-lc", "npx --yes --prefer-offline tether-server@\(ServerRelease.version) version --json"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("\"version\":\"\(ServerRelease.version)\""))
    }
}
