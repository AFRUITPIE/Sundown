import Foundation

/// The Tether server this build of the app runs on a host: tether-server's npm package at the
/// version pinned in `ServerPin.swift`, run by the first `npx` on the host's login-shell PATH, so
/// nothing is installed and no script is run. A host without Node.js 18 or later can have the
/// release's binary copied to it instead, checked against the checksums pinned beside the version.
public enum ServerRelease {
    /// The oldest Node.js the package runs on (its `engines`).
    public static let minimumNode = 18

    /// What connecting runs on a host with Node.js. `--prefer-offline` takes the package from npm's
    /// cache once it's there, so a reconnect doesn't wait on the registry.
    static func npxCommand(version: String = version) -> String {
        "npx --yes --prefer-offline tether-server@\(version) connect"
    }

    /// Where the releases' binaries are, for a copy; `TETHER_DOWNLOAD_BASE` points at a mirror, or
    /// at a local server while developing.
    static var downloadBase: String {
        ProcessInfo.processInfo.environment["TETHER_DOWNLOAD_BASE"]
            ?? "https://github.com/AFRUITPIE/tether-server/releases/download"
    }

    static func url(_ file: String, version: String = version) -> URL {
        URL(string: "\(downloadBase)/v\(version)/\(file)")!
    }

    static func binaryName(version: String, platform: String) -> String { "tether-\(version)-\(platform)" }

    /// Where a copied binary goes on a host, by version: `connect` runs this one, and a copy of a
    /// later version clears the others away.
    static let directory = "~/.tether/bin"
    static func copiedPath(version: String = version) -> String { "\(directory)/tether-\(version)" }
}

/// What `tether version --json` says about a server.
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

/// A host as the check found it, before connecting.
public struct ServerProbe: Sendable, Equatable {
    /// `darwin-arm64`, `linux-x64` and so on; nil for a system Tether has no build for.
    public var platform: String?
    /// The version of the first `node` on the host's login-shell PATH, without the `v`; nil when
    /// that PATH has no `npx`.
    public var node: String?
    /// This app's version of the server, when it was copied to the host.
    public var copied: InstalledServer?

    public init(platform: String?, node: String? = nil, copied: InstalledServer? = nil) {
        self.platform = platform
        self.node = node
        self.copied = copied
    }
}

/// How a host runs the server.
public enum ServerRunner: Sendable, Equatable {
    /// `npx`, with this version of Node.js.
    case npx(node: String)
    /// The binary copied to the host.
    case copied
}

/// Install Tether, for a host without Node.js: the release's binary, which this Mac downloads,
/// checks and copies there. Never done unasked.
public struct ServerCopy: Sendable, Equatable, Identifiable {
    public let version: String
    public let platform: String
    /// Why the last try failed, for Try Again.
    public var failure: String?

    public init(version: String = ServerRelease.version, platform: String, failure: String? = nil) {
        self.version = version
        self.platform = platform
        self.failure = failure
    }

    public var id: String { "\(version) \(platform)" }
}

/// A host without Node.js 18 or later: what it has, and the copy offered instead.
public struct NodeNeeded: Sendable, Equatable {
    /// The Node.js it has, when that's too old.
    public var found: String?
    /// Nil when there's no build of the server for the host's system.
    public var copy: ServerCopy?

    public init(found: String? = nil, copy: ServerCopy?) {
        self.found = found
        self.copy = copy
    }
}

/// What the app does with a host after checking it.
public enum ServerAssessment: Sendable, Equatable {
    case ready(ServerRunner)
    case needsNode(NodeNeeded)

    /// A copy of this app's server is run first: the user chose it, and it needs no network.
    public static func of(_ probe: ServerProbe, release: String = ServerRelease.version,
                          checksums: [String: String] = ServerRelease.checksums) -> ServerAssessment {
        if let copied = probe.copied, copied.version == release { return .ready(.copied) }
        if let node = probe.node, (ServerVersion(node).parts.first ?? 0) >= ServerRelease.minimumNode {
            return .ready(.npx(node: node))
        }
        let copy = probe.platform.flatMap { platform in
            checksums[platform] == nil ? nil : ServerCopy(version: release, platform: platform)
        }
        return .needsNode(NodeNeeded(found: probe.node, copy: copy))
    }
}

/// A version's numbers, so 0.10.0 orders above 0.9.0 and a dev build (`0.5.6-dev.<time>`) counts
/// as the release it leads to.
struct ServerVersion: Comparable {
    let parts: [Int]

    init(_ string: String) {
        let trimmed = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
        parts = trimmed.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
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
