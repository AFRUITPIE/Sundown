import Foundation
import Synchronization

/// Locates bundled server binaries and installs the right one on a host, then
/// builds the command that connects to that host's Tether daemon.
public struct HostBootstrapper: Sendable {
    public struct Binary: Sendable {
        public let url: URL
        public let version: String
        public let platform: String // e.g. darwin-arm64, linux-x64

        /// Numeric per component, so 0.10.0 orders above 0.9.0.
        var versionOrder: [Int] {
            version.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }

    }

    public enum BootstrapError: LocalizedError {
        case noBinaries
        case unsupportedPlatform(String)
        case command(String, String)

        public var errorDescription: String? {
            switch self {
            case .noBinaries: return "No bundled Tether server binaries found."
            case .unsupportedPlatform(let p): return "No Tether server build for \(p)."
            case .command(let cmd, let err): return "\(cmd) failed: \(err)"
            }
        }
    }

    /// Directories searched for `tether-<version>-<platform>` binaries.
    public var searchDirectories: [URL]
    public var log: @Sendable (String) -> Void

    public init(searchDirectories: [URL]? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["TETHER_SERVER_DIST"] { dirs.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("servers")) }
        dirs.append(URL(fileURLWithPath: NSString(string: "~/Code/tether-server/dist").expandingTildeInPath))
        self.searchDirectories = searchDirectories ?? dirs
        self.log = log
    }

    public func availableBinaries() -> [Binary] {
        var out: [Binary] = []
        let re = try! Regex(#"^tether-(\d+\.\d+\.\d+(?:-[\w.]+)?)-(darwin|linux)-(arm64|x64)$"#, as: (Substring, Substring, Substring, Substring).self)
        for dir in searchDirectories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names {
                if let m = n.wholeMatch(of: re) {
                    out.append(Binary(url: dir.appendingPathComponent(n), version: String(m.1), platform: "\(m.2)-\(m.3)"))
                }
            }
            if !out.isEmpty { break }
        }
        // Newest first: an incremental build can leave an older version in the bundle, and running it
        // would also match the old daemon's version and so never trigger the upgrade.
        return out.sorted { $1.versionOrder.lexicographicallyPrecedes($0.versionOrder) }
    }

    /// Returns the argv to launch for this host, installing the server first if needed.
    public func connectCommand(for host: HostConfig) async throws -> (executable: String, arguments: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let ssh = Self.sshOptions + Self.sharedConnectionOptions()
        if let custom = host.serverCommand, !custom.isEmpty {
            switch host.kind {
            case .local: return (shell, ["-lc", custom])
            case .ssh(let dest): return ("/usr/bin/ssh", ssh + [dest, custom])
            }
        }
        let all = availableBinaries()
        guard let version = all.first?.version else { throw BootstrapError.noBinaries }
        // Only the newest version: an older one for this platform would be installed under the new name.
        let binaries = all.filter { $0.version == version }
        let remotePath = "~/.tether/bin/tether-\(version)"
        switch host.kind {
        case .local:
            let platform = "darwin-\(Self.localArch)"
            guard let bin = binaries.first(where: { $0.platform == platform }) else { throw BootstrapError.unsupportedPlatform(platform) }
            let dest = URL(fileURLWithPath: NSString(string: remotePath).expandingTildeInPath)
            if !FileManager.default.isExecutableFile(atPath: dest.path) || Self.differs(bin.url, dest) {
                log("Installing Tether \(version) locally")
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = dest.appendingPathExtension("tmp")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: bin.url, to: tmp)
                _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)
                if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.moveItem(at: tmp, to: dest) }
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                Self.pruneDevBuilds(in: dest.deletingLastPathComponent(), keeping: dest.lastPathComponent)
            }
            return (shell, ["-lc", "exec \(dest.path) connect"])

        case .ssh(let destHost):
            // Checked once a session: a reconnect goes straight to `connect`, one SSH login rather
            // than two. A failed attempt forgets it (`forgetInstall`), so a server gone since is put back.
            let key = "\(destHost) \(version)"
            if !Self.installed.withLock({ $0.contains(key) }) {
                log("Checking \(destHost)")
                let probe = try await Self.run("/usr/bin/ssh", ssh + [destHost, "uname -sm; test -x \(remotePath) && echo TETHER_PRESENT; true"])
                let lines = probe.split(separator: "\n").map(String.init)
                guard let uname = lines.first else { throw BootstrapError.command("ssh", "no output from \(destHost)") }
                let platform = try Self.platform(fromUname: uname)
                if !lines.contains("TETHER_PRESENT") {
                    guard let bin = binaries.first(where: { $0.platform == platform }) else { throw BootstrapError.unsupportedPlatform(platform) }
                    log("Uploading Tether \(version) (\(platform)) to \(destHost)")
                    _ = try await Self.run("/usr/bin/ssh", ssh + [destHost, "mkdir -p ~/.tether/bin"])
                    _ = try await Self.run("/usr/bin/scp", ["-q", "-o", "BatchMode=yes"] + Self.sharedConnectionOptions()
                                           + [bin.url.path, "\(destHost):.tether/bin/tether-\(version).tmp"])
                    // A dev build replaces the previous one rather than piling up beside it.
                    let prune = version.contains("-dev.") ? " && find ~/.tether/bin -name 'tether-*-dev.*' ! -name 'tether-\(version)' -delete" : ""
                    _ = try await Self.run("/usr/bin/ssh", ssh + [destHost, "chmod +x \(remotePath).tmp && mv -f \(remotePath).tmp \(remotePath)\(prune)"])
                }
                Self.installed.withLock { _ = $0.insert(key) }
            }
            // Run under the remote user's login shell so PATH (and the first `claude`) match their terminal.
            let remote = "exec \"$SHELL\" -lc 'exec \(remotePath) connect'"
            return ("/usr/bin/ssh", ssh + [destHost, remote])
        }
    }

    /// Destinations and versions found installed this session, as "<destination> <version>".
    private static let installed = Mutex<Set<String>>([])

    /// The next connection to `host` checks again for the server before starting it.
    public static func forgetInstall(on host: HostConfig) {
        guard let destination = host.sshDestination else { return }
        installed.withLock { $0 = $0.filter { !$0.hasPrefix(destination + " ") } }
    }

    /// Local development compiles a new `-dev.<time>` build whenever the server changes; each would
    /// otherwise stay in `~/.tether/bin` (about 70 MB apiece). A running daemon keeps its deleted file.
    static func pruneDevBuilds(in dir: URL, keeping name: String) {
        guard name.contains("-dev.") else { return }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where file.hasPrefix("tether-") && file.contains("-dev.") && file != name {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// A keepalive every 30 s, not 15: each wakes the radio on both ends, and a connection that died
    /// quietly is still noticed within two minutes.
    public static let sshOptions = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4", "-o", "ConnectTimeout=15"]

    /// One SSH connection per host for the check, the upload and the session, kept a minute after
    /// the last of them: each was a login of its own (a TCP and SSH handshake, and the host's
    /// authentication). The socket goes in `~/.ssh`, private to the user. Nothing when that isn't
    /// a folder, or the path would be too long for a socket: ssh stops rather than going on
    /// without one.
    static func sharedConnectionOptions(home: String = NSHomeDirectory(),
                                        isFolder: (String) -> Bool = folderExists) -> [String] {
        let folder = (home as NSString).appendingPathComponent(".ssh")
        // Written into ssh's own option syntax: a space or a quote would need quoting there.
        guard !home.contains(where: { $0.isWhitespace || "%\"'".contains($0) }), isFolder(folder) else { return [] }
        let path = folder + "/tether-%C"
        // %C is 40 characters, and ssh adds 17 to the name while it makes the socket; a socket's
        // path is at most 103 bytes.
        guard path.utf8.count - 2 + 40 + 17 <= 103 else { return [] }
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(path)", "-o", "ControlPersist=60"]
    }

    static func folderExists(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    static var localArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    static func platform(fromUname s: String) throws -> String {
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { throw BootstrapError.unsupportedPlatform(s) }
        let os = parts[0] == "Darwin" ? "darwin" : parts[0] == "Linux" ? "linux" : ""
        let arch: String
        switch parts[1] {
        case "arm64", "aarch64": arch = "arm64"
        case "x86_64", "amd64": arch = "x64"
        default: arch = ""
        }
        guard !os.isEmpty, !arch.isEmpty else { throw BootstrapError.unsupportedPlatform(s) }
        return "\(os)-\(arch)"
    }

    static func differs(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        let sa = (try? fm.attributesOfItem(atPath: a.path)[.size] as? Int) ?? -1
        let sb = (try? fm.attributesOfItem(atPath: b.path)[.size] as? Int) ?? -2
        return sa != sb
    }

    static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { cont.resume(returning: o) }
                else { cont.resume(throwing: BootstrapError.command(([exe] + args).joined(separator: " "), e.isEmpty ? "exit \(proc.terminationStatus)" : e)) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
