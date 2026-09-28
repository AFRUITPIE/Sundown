import Foundation
import Synchronization
import Testing
@testable import TetherKit

/// Installing a real release on this Mac, both ways the app does it: the command the user is shown,
/// and this Mac downloading, checking and installing it itself. Opt in, against a release served
/// locally, into a folder of the test's own (never `~/.tether`):
///
///     TETHER_INSTALL_E2E=1 TETHER_DOWNLOAD_BASE=http://127.0.0.1:8765 TETHER_INSTALL_DIR=/tmp/tether-e2e/bin \
///         swift test --package-path TetherKit --filter ServerInstallEndToEnd
///
/// with `<base>/v<ServerRelease.version>/` holding a compiled release (`mise run compile` in tether-server).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TETHER_INSTALL_E2E"] == "1"
                               && ProcessInfo.processInfo.environment["TETHER_INSTALL_DIR"] != nil))
struct ServerInstallEndToEndTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TETHER_INSTALL_DIR"] ?? "/nonexistent")
    private var offer: ServerOffer { ServerOffer(reason: .missing, platform: "darwin-\(HostBootstrapper.localArch)") }

    /// What `tether` in the folder says it is, once installed.
    private func installedVersion() async throws -> InstalledServer? {
        let link = folder.appending(path: "tether")
        return HostBootstrapper.installedServer(try await HostBootstrapper.run(link.path, ["version", "--json"]))
    }

    @Test func theCommandShownInstallsTheRelease() async throws {
        try? FileManager.default.removeItem(at: folder)
        let lines = Mutex<[String]>([])
        try await HostBootstrapper().install(offer, on: .local) { line in lines.withLock { $0.append(line) } }
        #expect(lines.withLock { $0.last } == "Installed Tether \(ServerRelease.version)")
        #expect(try await installedVersion()?.version == ServerRelease.version)
    }

    /// The path for a host that can't reach the releases: downloaded and checked here first.
    @Test func thisMacDownloadsChecksAndInstallsIt() async throws {
        try? FileManager.default.removeItem(at: folder)
        let lines = Mutex<[String]>([])
        try await HostBootstrapper().installFromThisMac(offer, on: .local) { line in lines.withLock { $0.append(line) } }
        #expect(lines.withLock { $0 }.contains("Verifying"))
        #expect(try await installedVersion()?.version == ServerRelease.version)
    }
}
