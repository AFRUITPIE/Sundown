import Foundation
import Synchronization
import Testing
import TetherProtocol
@testable import TetherKit

@Suite
struct ServerAssessmentTests {
    private func probe(_ installed: InstalledServer?) -> ServerProbe { ServerProbe(platform: "linux-x64", installed: installed) }

    @Test func nothingInstalledIsOfferedAnInstall() {
        #expect(ServerAssessment.of(probe(nil), clientProtocol: 1, minServerProtocol: 1, release: "0.5.6")
                == .needs(ServerOffer(reason: .missing, version: "0.5.6", platform: "linux-x64")))
    }

    /// Too old to talk to: connecting waits for the update.
    @Test func aServerTooOldNeedsAnUpdate() {
        let old = InstalledServer(version: "0.4.0", protocolVersion: 0, minClientProtocol: 0)
        #expect(ServerAssessment.of(probe(old), clientProtocol: 1, minServerProtocol: 1, release: "0.5.6")
                == .needs(ServerOffer(reason: .outdated(installed: "0.4.0"), version: "0.5.6", platform: "linux-x64")))
    }

    @Test func aServerTooNewNeedsANewerApp() {
        let new = InstalledServer(version: "0.9.0", protocolVersion: 2, minClientProtocol: 2)
        #expect(ServerAssessment.of(probe(new), clientProtocol: 1, minServerProtocol: 1) == .appTooOld(serverVersion: "0.9.0"))
    }

    /// An older server that still works connects, with the newer one offered beside it; the same or
    /// a newer one offers nothing.
    @Test func anOlderWorkingServerIsOfferedAnUpdate() {
        let older = InstalledServer(version: "0.5.5", protocolVersion: 1, minClientProtocol: 1)
        #expect(ServerAssessment.of(probe(older), clientProtocol: 1, minServerProtocol: 1, release: "0.5.6")
                == .ready(older, update: ServerOffer(reason: .newer(installed: "0.5.5"), version: "0.5.6", platform: "linux-x64")))
        for version in ["0.5.6", "0.5.7", "0.5.6-dev.20260928"] {
            let current = InstalledServer(version: version, protocolVersion: 1, minClientProtocol: 1)
            #expect(ServerAssessment.of(probe(current), clientProtocol: 1, minServerProtocol: 1, release: "0.5.6") == .ready(current, update: nil))
        }
    }

    @Test func versionsOrderByTheirNumbers() {
        #expect(ServerVersion("0.9.0") < ServerVersion("0.10.0"))
        #expect(ServerVersion("0.5") < ServerVersion("0.5.1"))
        #expect(!(ServerVersion("0.5.6-dev.1") < ServerVersion("0.5.6")))
    }
}

@Suite
struct ServerDownloadTests {
    @Test func checksumsAreFoundByFileName() {
        let sums = """
        aa11  tether-0.5.6-darwin-arm64
        BB22 *tether-0.5.6-linux-x64

        """
        #expect(ReleaseChecksums.digest(of: "tether-0.5.6-darwin-arm64", in: sums) == "aa11")
        #expect(ReleaseChecksums.digest(of: "tether-0.5.6-linux-x64", in: sums) == "bb22")
        #expect(ReleaseChecksums.digest(of: "tether-0.5.6-linux-arm64", in: sums) == nil)
    }

    /// A login script's banner around the JSON doesn't hide it; anything else is "not installed".
    @Test func versionOutputIsReadThroughNoise() {
        let json = #"{"version":"0.5.6","protocolVersion":1,"minClientProtocol":1,"agentSdkVersion":"0.3.278","platform":"linux-x64"}"#
        #expect(HostBootstrapper.installedServer("Welcome to claude-box\n\(json)\n")
                == InstalledServer(version: "0.5.6", protocolVersion: 1, minClientProtocol: 1, agentSdkVersion: "0.3.278", platform: "linux-x64"))
        #expect(HostBootstrapper.installedServer("") == nil)
        #expect(HostBootstrapper.installedServer("sh: tether: not found") == nil)
    }

    /// What an earlier version of the app left in ~/.tether/bin counts as installed, and too old.
    @Test func anEarlierInstallIsOfferedAnUpdate() {
        let names = ["tether-0.4.0", "tether-0.5.4", "tether-0.5.4-dev.20260927193708", "tether-0.10.1.tmp", "notes.txt"]
        let found = HostBootstrapper.earlierInstall(names)
        #expect(found == InstalledServer(version: "0.5.4", protocolVersion: 0, minClientProtocol: 0))
        #expect(HostBootstrapper.earlierInstall(["notes.txt"]) == nil)
        guard case .needs(let offer) = ServerAssessment.of(ServerProbe(platform: "darwin-arm64", installed: found),
                                                           clientProtocol: 1, minServerProtocol: 1) else {
            Issue.record("Expected an update offer")
            return
        }
        #expect(offer.reason == .outdated(installed: "0.5.4"))
    }

    @Test func theCommandShownIsTheOneRun() {
        let offer = ServerOffer(reason: .missing, version: "0.5.6", platform: "linux-x64")
        #expect(offer.command == "curl -fsSL https://github.com/AFRUITPIE/tether-server/releases/download/v0.5.6/install.sh | sh")
    }

    /// Connecting runs what's installed, by its link; a Server Command is run as it is.
    @Test func connectRunsTheInstalledServer() {
        let boot = HostBootstrapper()
        #expect(boot.connectCommand(for: .local).arguments.last == "exec ~/.tether/bin/tether connect")
        let ssh = boot.connectCommand(for: HostConfig(name: "box", kind: .ssh(destination: "box")))
        #expect(ssh.executable == "/usr/bin/ssh")
        #expect(ssh.arguments.suffix(2) == ["box", "exec \"$SHELL\" -lc 'exec ~/.tether/bin/tether connect'"])
        var custom = HostConfig.local
        custom.serverCommand = "bun run ../tether-server/src/cli.ts connect"
        #expect(boot.connectCommand(for: custom).arguments.last == "bun run ../tether-server/src/cli.ts connect")
    }

    /// install.sh's lines reach the log as they come, without their prefix; its error line is the
    /// reason given.
    @Test func installerLinesStreamAndItsErrorIsTheReason() async throws {
        let lines = Mutex<[String]>([])
        let script = #"echo "tether-install: Downloading"; echo "tether-install: Verifying"; echo "tether-install: error: checksum mismatch" >&2; exit 1"#
        await #expect(throws: HostBootstrapper.BootstrapError.self) {
            try await HostBootstrapper.stream("/bin/sh", ["-c", script]) { line in lines.withLock { $0.append(line) } }
        }
        #expect(lines.withLock { $0 } == ["Downloading", "Verifying"])
        do {
            try await HostBootstrapper.stream("/bin/sh", ["-c", script]) { _ in }
        } catch {
            #expect(error.localizedDescription == "checksum mismatch")
        }
    }

    /// Standard input reaches the script: how install.sh gets to `sh -s` on a host.
    @Test func inputReachesTheScript() async throws {
        let lines = Mutex<[String]>([])
        try await HostBootstrapper.stream("/bin/sh", ["-s"], input: Data("echo \"tether-install: from stdin\"\n".utf8)) { line in
            lines.withLock { $0.append(line) }
        }
        #expect(lines.withLock { $0 } == ["from stdin"])
    }

    @Test func aFilesDigestIsItsSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tether-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try HostBootstrapper.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// The connection's side, on fixture hosts: nothing installed without asking, and what happens next.
@MainActor
@Suite
struct ServerInstallFlowTests {
    @Test func aMissingServerIsAskedAboutThenInstalledAndConnected() async throws {
        let connection = UITestFixture.connection(server: .missing)
        await connection.connect()
        guard case .needsServer(let offer) = connection.state else {
            Issue.record("Expected an install offer, got \(connection.state)")
            return
        }
        #expect(offer.reason == .missing)
        #expect(!connection.isInstalling)
        await connection.installServer(offer)
        #expect(connection.state == .connected)
        #expect(connection.log.contains("Installed Tether \(ServerRelease.version)"))
        await connection.disconnect()
    }

    @Test func aFailedInstallSaysWhyAndCanBeTriedAgain() async {
        let connection = UITestFixture.connection(server: .installFails)
        await connection.connect()
        guard case .needsServer(let offer) = connection.state else {
            Issue.record("Expected an install offer, got \(connection.state)")
            return
        }
        await connection.installServer(offer)
        guard case .needsServer(let failed) = connection.state else {
            Issue.record("Expected the offer back with its failure, got \(connection.state)")
            return
        }
        #expect(failed.failure?.contains("404") == true)
    }

    @Test func aServerTooNewSaysTheAppIsTooOld() async {
        let connection = UITestFixture.connection(server: .tooNew)
        await connection.connect()
        #expect(connection.state == .appTooOld(serverVersion: "0.9.0"))
    }

    @Test func anOutdatedServerNeedsItsUpdateFirst() async {
        let connection = UITestFixture.connection(server: .outdated)
        await connection.connect()
        guard case .needsServer(let offer) = connection.state else {
            Issue.record("Expected an update offer, got \(connection.state)")
            return
        }
        #expect(offer.reason == .outdated(installed: "0.4.0"))
        #expect(offer.isUpdate)
    }
}
