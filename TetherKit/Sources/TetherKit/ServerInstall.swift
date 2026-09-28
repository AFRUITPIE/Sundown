import Foundation

/// The Tether server this build of the app installs on a host, from tether-server's public
/// releases: an `install.sh`, one binary per platform, and their `SHA256SUMS`. A host installs and
/// updates it itself (`curl … | sh`); the app only asks first, and runs what it showed.
public enum ServerRelease {
    /// Installed on a host that has none, and offered to one with an older version. Moves with the
    /// protocol package's pin, which is the server this app was built against.
    public static let version = "0.5.6"

    /// Where the releases are; `TETHER_DOWNLOAD_BASE`, install.sh's own override, points at a
    /// mirror, or at a local server while developing.
    static var downloadBase: String {
        ProcessInfo.processInfo.environment["TETHER_DOWNLOAD_BASE"]
            ?? "https://github.com/AFRUITPIE/tether-server/releases/download"
    }

    static func url(_ file: String, version: String = version) -> URL {
        URL(string: "\(downloadBase)/v\(version)/\(file)")!
    }

    static func binaryName(version: String, platform: String) -> String { "tether-\(version)-\(platform)" }

    /// What runs on the host, as the app shows it before running it: install.sh has its release's
    /// version in it, so nothing needs setting, which a fish login shell would read differently.
    public static func installCommand(version: String = version) -> String {
        "curl -fsSL \(url("install.sh", version: version).absoluteString) | sh"
    }

    /// Where a host keeps it, and the name `connect` runs by: a link to the version installed.
    static let installedPath = "~/.tether/bin/tether"
}

/// What `tether version --json` says about a host's server.
public struct InstalledServer: Codable, Sendable, Equatable {
    public let version: String
    public let protocolVersion: Int
    public let minClientProtocol: Int
    public let agentSdkVersion: String?
    public let platform: String?

    public init(version: String, protocolVersion: Int, minClientProtocol: Int, agentSdkVersion: String? = nil, platform: String? = nil) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.minClientProtocol = minClientProtocol
        self.agentSdkVersion = agentSdkVersion
        self.platform = platform
    }
}

/// A host's server as the app found it, before connecting.
public struct ServerProbe: Sendable, Equatable {
    /// `darwin-arm64`, `linux-x64` and so on.
    public let platform: String
    /// Nil when there's no `~/.tether/bin/tether`, or it didn't answer.
    public let installed: InstalledServer?

    public init(platform: String, installed: InstalledServer?) {
        self.platform = platform
        self.installed = installed
    }
}

/// The server the app offers a host: to install, or to update to. Never done unasked.
public struct ServerOffer: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        /// Nothing installed: the app can't connect until it is.
        case missing
        /// Too old for this app to talk to: it can't connect until it's updated.
        case outdated(installed: String)
        /// Older than this app's, but it still works: an update is offered, not needed.
        case newer(installed: String)
    }

    public let reason: Reason
    public let version: String
    public let platform: String
    /// Bytes to download, when the release says.
    public var size: Int64?
    /// Why the last try failed, for Try Again.
    public var failure: String?

    public init(reason: Reason, version: String = ServerRelease.version, platform: String, size: Int64? = nil, failure: String? = nil) {
        self.reason = reason
        self.version = version
        self.platform = platform
        self.size = size
        self.failure = failure
    }

    public var id: String { "\(version) \(platform)" }
    public var command: String { ServerRelease.installCommand(version: version) }
    public var isUpdate: Bool { reason != .missing }
}

/// What the app does with a host after looking at its server.
public enum ServerAssessment: Sendable, Equatable {
    /// Connect; `update` is offered alongside when there's a newer server than the one installed.
    case ready(InstalledServer, update: ServerOffer?)
    /// Ask to install or update first.
    case needs(ServerOffer)
    /// The host's server is newer than this app can talk to.
    case appTooOld(serverVersion: String)

    /// `clientProtocol` is this app's protocol version, `minServerProtocol` the oldest it talks to.
    public static func of(_ probe: ServerProbe, clientProtocol: Int, minServerProtocol: Int,
                          release: String = ServerRelease.version) -> ServerAssessment {
        guard let installed = probe.installed else {
            return .needs(ServerOffer(reason: .missing, version: release, platform: probe.platform))
        }
        if installed.minClientProtocol > clientProtocol {
            return .appTooOld(serverVersion: installed.version)
        }
        if installed.protocolVersion < minServerProtocol {
            return .needs(ServerOffer(reason: .outdated(installed: installed.version), version: release, platform: probe.platform))
        }
        let update = ServerVersion(installed.version) < ServerVersion(release)
            ? ServerOffer(reason: .newer(installed: installed.version), version: release, platform: probe.platform) : nil
        return .ready(installed, update: update)
    }
}

/// A version's numbers, so 0.10.0 orders above 0.9.0 and a dev build (`0.5.6-dev.<time>`) counts
/// as the release it leads to.
struct ServerVersion: Comparable {
    let parts: [Int]

    init(_ string: String) {
        parts = string.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (a: ServerVersion, b: ServerVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        let pad = { (p: [Int]) in p + Array(repeating: 0, count: count - p.count) }
        return pad(a.parts).lexicographicallyPrecedes(pad(b.parts))
    }
}

/// A release's `SHA256SUMS`: `<hex>  <file>` per line, as `sha256sum -c` reads it.
enum ReleaseChecksums {
    static func digest(of file: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            // `sha256sum` marks a file read in binary mode with a leading `*`.
            let name = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            if name == file { return fields[0].lowercased() }
        }
        return nil
    }
}
