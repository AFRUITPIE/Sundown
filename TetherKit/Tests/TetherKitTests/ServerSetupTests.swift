import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

@Suite
struct ServerAssessmentTests {
    private let sums = ["linux-x64": "aa11"]

    @Test func nodeOnThePathRunsNpx() {
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-x64", node: "22.3.0"), checksums: sums) == .ready(.npx(node: "22.3.0")))
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-x64", node: "18.0.0"), checksums: sums) == .ready(.npx(node: "18.0.0")))
    }

    /// No npx, or a Node.js too old for the package: the copy is offered, where there's a build.
    @Test func withoutNodeTheCopyIsOffered() {
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-x64"), release: "0.5.7", checksums: sums)
                == .needsNode(NodeNeeded(copy: ServerCopy(version: "0.5.7", platform: "linux-x64"))))
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-x64", node: "16.20.2"), release: "0.5.7", checksums: sums)
                == .needsNode(NodeNeeded(found: "16.20.2", copy: ServerCopy(version: "0.5.7", platform: "linux-x64"))))
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-arm64"), checksums: sums) == .needsNode(NodeNeeded(copy: nil)))
        #expect(ServerAssessment.of(ServerProbe(platform: nil), checksums: sums) == .needsNode(NodeNeeded(copy: nil)))
    }

    /// A copy of this app's version is run before npx; another version's isn't run at all.
    @Test func aCopyOfThisVersionRunsFirst() {
        let copied = InstalledServer(version: "0.5.7", protocolVersion: 1, minClientProtocol: 1)
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-x64", node: "22.3.0", copied: copied), release: "0.5.7", checksums: sums)
                == .ready(.copied))
        #expect(ServerAssessment.of(ServerProbe(platform: "linux-x64", node: "22.3.0", copied: copied), release: "0.5.8", checksums: sums)
                == .ready(.npx(node: "22.3.0")))
    }

    @Test func versionsOrderByTheirNumbers() {
        #expect(ServerVersion("0.9.0") < ServerVersion("0.10.0"))
        #expect(ServerVersion("0.5") < ServerVersion("0.5.1"))
        #expect(!(ServerVersion("0.5.6-dev.1") < ServerVersion("0.5.6")))
        #expect(ServerVersion("v22.3.0").parts == [22, 3, 0])
    }
}

@Suite
struct ServerProbeTests {
    /// A login script's banner before the probe's marker doesn't hide what follows it.
    @Test func theProbeIsReadAfterItsMarker() throws {
        let json = #"{"version":"0.5.7","protocolVersion":1,"minClientProtocol":1,"agentSdkVersion":"0.3.278","platform":"linux-x64"}"#
        let probe = try HostBootstrapper.parseProbe("Welcome to claude-box\ntether-probe\nLinux x86_64\nv22.3.0\n\(json)\n")
        #expect(probe == ServerProbe(platform: "linux-x64", node: "22.3.0",
                                     copied: InstalledServer(version: "0.5.7", protocolVersion: 1, minClientProtocol: 1,
                                                             agentSdkVersion: "0.3.278", platform: "linux-x64")))
        #expect(try HostBootstrapper.parseProbe("tether-probe\nDarwin arm64\n") == ServerProbe(platform: "darwin-arm64"))
        #expect(try HostBootstrapper.parseProbe("tether-probe\nFreeBSD amd64\nv20.1.0\n") == ServerProbe(platform: nil, node: "20.1.0"))
        #expect(throws: HostBootstrapper.BootstrapError.self) { try HostBootstrapper.parseProbe("sh: not found") }
    }

    /// The probe as the login shells people use run it, from nothing but the system's PATH.
    @Test(arguments: ["/bin/sh", "/bin/zsh", "/bin/bash"])
    func theProbeRunsInEachShell(_ shell: String) async throws {
        let output = try await HostBootstrapper.run(shell, ["-c", HostBootstrapper.probeCommand])
        let probe = try HostBootstrapper.parseProbe(output)
        #expect(probe.platform == "darwin-\(HostBootstrapper.localArch)")
    }

    @Test func checksumsAreFoundByFileName() {
        let sums = """
        aa11  tether-0.5.7-darwin-arm64
        BB22 *tether-0.5.7-linux-x64

        """
        #expect(ReleaseChecksums.digest(of: "tether-0.5.7-darwin-arm64", in: sums) == "aa11")
        #expect(ReleaseChecksums.digest(of: "tether-0.5.7-linux-x64", in: sums) == "bb22")
        #expect(ReleaseChecksums.digest(of: "tether-0.5.7-linux-arm64", in: sums) == nil)
    }

    /// Connecting runs npx, or the copy, under the login shell; a Server Command is run as it is.
    @Test func connectRunsNpxOrTheCopy() {
        let boot = HostBootstrapper()
        let npx = "npx --yes --prefer-offline tether-server@\(ServerRelease.version) connect"
        #expect(boot.connectCommand(for: .local, runner: .npx(node: "22.3.0")).arguments == ["-lc", "exec \(npx)"])
        #expect(boot.connectCommand(for: .local, runner: .copied).arguments.last == "exec ~/.tether/bin/tether-\(ServerRelease.version) connect")
        let ssh = boot.connectCommand(for: HostConfig(name: "box", kind: .ssh(destination: "box")), runner: .npx(node: "22.3.0"))
        #expect(ssh.executable == "/usr/bin/ssh")
        #expect(ssh.arguments.suffix(2) == ["box", "exec \"$SHELL\" -lc 'exec \(npx)'"])
        var custom = HostConfig.local
        custom.serverCommand = "bun run ../tether-server/src/cli.ts connect"
        #expect(boot.connectCommand(for: custom, runner: nil).arguments.last == "bun run ../tether-server/src/cli.ts connect")
    }

    @Test func aFilesDigestIsItsSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tether-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try HostBootstrapper.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// A copy goes in whole and executable, and clears away the other versions.
    @Test func aCopyReplacesTheOtherVersions() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appending(path: "tether-place-\(UUID().uuidString)")
        defer { try? files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["tether-0.5.4", "tether", "tether-0.5.7.part", "notes.txt"] {
            try Data("old".utf8).write(to: folder.appending(path: name))
        }
        let binary = files.temporaryDirectory.appending(path: "tether-binary-\(UUID().uuidString)")
        defer { try? files.removeItem(at: binary) }
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try HostBootstrapper.place(binary, version: "0.5.7", in: folder)
        #expect(try files.contentsOfDirectory(atPath: folder.path).sorted() == ["notes.txt", "tether-0.5.7"])
        #expect(files.isExecutableFile(atPath: folder.appending(path: "tether-0.5.7").path))
    }

    /// Nothing is downloaded for a platform the app has no checksum for.
    @Test func aCopyNeedsItsChecksum() async {
        await #expect(throws: HostBootstrapper.BootstrapError.self) {
            _ = try await HostBootstrapper().download(ServerCopy(version: "0.0.0", platform: "plan9-mips")) { _ in }
        }
    }
}

/// The connection's side, on fixture hosts: nothing copied without asking, and what happens next.
@MainActor
@Suite
struct ServerCopyFlowTests {
    @Test func aHostWithoutNodeIsAskedThenCopiedToAndConnected() async throws {
        let connection = UITestFixture.connection(server: .nodeMissing)
        await connection.connect()
        guard case .needsNode(let need) = connection.state, let copy = need.copy else {
            Issue.record("Expected a copy offer, got \(connection.state)")
            return
        }
        #expect(need.found == nil)
        #expect(!connection.isCopying)
        await connection.copyServer(copy)
        #expect(connection.state == .connected)
        #expect(connection.runner == .copied)
        #expect(connection.log.contains("Installed Tether \(ServerRelease.version)"))
        await connection.disconnect()
    }

    @Test func aFailedCopySaysWhyAndCanBeTriedAgain() async {
        let connection = UITestFixture.connection(server: .copyFails)
        await connection.connect()
        guard case .needsNode(let need) = connection.state, let copy = need.copy else {
            Issue.record("Expected a copy offer, got \(connection.state)")
            return
        }
        await connection.copyServer(copy)
        guard case .needsNode(let failed) = connection.state else {
            Issue.record("Expected the offer back with its failure, got \(connection.state)")
            return
        }
        #expect(failed.copy?.failure?.contains("404") == true)
    }

    @Test func anOldNodeIsNamed() async {
        let connection = UITestFixture.connection(server: .nodeOutdated)
        await connection.connect()
        guard case .needsNode(let need) = connection.state else {
            Issue.record("Expected Node.js to be needed, got \(connection.state)")
            return
        }
        #expect(need.found == "16.20.2")
    }
}
