import Foundation
import Synchronization
import Testing
@testable import TetherKit

/// The two ways a host runs the real server, on this Mac. Opt in (`TETHER_SETUP_E2E=1`):
///
/// - npx runs the pinned package from npm, once that version is published.
/// - A copy, against a release served locally (`TETHER_DOWNLOAD_BASE=<base>`, with
///   `<base>/v<ServerRelease.version>/` holding `mise run compile`'s `dist/` in tether-server), is
///   downloaded, checked against that release's SHA256SUMS and put in a folder of the test's own,
///   never `~/.tether`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TETHER_SETUP_E2E"] == "1"))
struct ServerSetupEndToEndTests {
    @Test func npxRunsThePinnedPackage() async throws {
        let output = try await HostBootstrapper.run(HostBootstrapper.loginShell, [
            "-lc", "npx --yes --prefer-offline tether-server@\(ServerRelease.version) version --json"])
        #expect(HostBootstrapper.installedServer(output)?.version == ServerRelease.version)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TETHER_DOWNLOAD_BASE"] != nil))
    func aCopyIsDownloadedCheckedAndPutInPlace() async throws {
        let platform = "darwin-\(HostBootstrapper.localArch)"
        let name = ServerRelease.binaryName(version: ServerRelease.version, platform: platform)
        let sums = String(decoding: try await HostBootstrapper.data(ServerRelease.url("SHA256SUMS")), as: UTF8.self)
        let boot = HostBootstrapper(checksums: [platform: try #require(ReleaseChecksums.digest(of: name, in: sums))])
        let lines = Mutex<[String]>([])
        let binary = try await boot.download(ServerCopy(platform: platform)) { line in lines.withLock { $0.append(line) } }
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        #expect(lines.withLock { $0 }.contains("Checking it"))

        let folder = FileManager.default.temporaryDirectory.appending(path: "tether-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try HostBootstrapper.place(binary, version: ServerRelease.version, in: folder)
        let output = try await HostBootstrapper.run(folder.appending(path: "tether-\(ServerRelease.version)").path, ["version", "--json"])
        #expect(HostBootstrapper.installedServer(output)?.version == ServerRelease.version)
    }
}
