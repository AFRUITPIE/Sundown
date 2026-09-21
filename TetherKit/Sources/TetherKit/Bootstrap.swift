import Foundation

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
        if let custom = host.serverCommand, !custom.isEmpty {
            switch host.kind {
            case .local: return (shell, ["-lc", custom])
            case .ssh(let dest): return ("/usr/bin/ssh", Self.sshOptions + [dest, custom])
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
            }
            return (shell, ["-lc", "exec \(dest.path) connect"])

        case .ssh(let destHost):
            log("Checking \(destHost)")
            let probe = try await Self.run("/usr/bin/ssh", Self.sshOptions + [destHost, "uname -sm; test -x \(remotePath) && echo TETHER_PRESENT; true"])
            let lines = probe.split(separator: "\n").map(String.init)
            guard let uname = lines.first else { throw BootstrapError.command("ssh", "no output from \(destHost)") }
            let platform = try Self.platform(fromUname: uname)
            if !lines.contains("TETHER_PRESENT") {
                guard let bin = binaries.first(where: { $0.platform == platform }) else { throw BootstrapError.unsupportedPlatform(platform) }
                log("Uploading Tether \(version) (\(platform)) to \(destHost)")
                _ = try await Self.run("/usr/bin/ssh", Self.sshOptions + [destHost, "mkdir -p ~/.tether/bin"])
                _ = try await Self.run("/usr/bin/scp", ["-q", "-o", "BatchMode=yes", bin.url.path, "\(destHost):.tether/bin/tether-\(version).tmp"])
                _ = try await Self.run("/usr/bin/ssh", Self.sshOptions + [destHost, "chmod +x \(remotePath).tmp && mv -f \(remotePath).tmp \(remotePath)"])
            }
            // Run under the remote user's login shell so PATH (and the first `claude`) match their terminal.
            let remote = "exec \"$SHELL\" -lc 'exec \(remotePath) connect'"
            return ("/usr/bin/ssh", Self.sshOptions + [destHost, remote])
        }
    }

    public static let sshOptions = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "ConnectTimeout=15"]

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
