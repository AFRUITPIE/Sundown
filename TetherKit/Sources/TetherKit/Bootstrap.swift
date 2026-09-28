import CryptoKit
import Foundation

/// What the app does with a host's server before connecting: checks for Node.js (or a copied
/// server), copies the server over when the user says to, and builds the command that connects. A
/// seam, so the UI tests' fixture hosts can be without Node.js, or fail to copy.
public protocol ServerProvisioning: Sendable {
    func probe(_ host: HostConfig) async throws -> ServerProbe
    /// Each platform's binary's SHA-256: the platforms a copy can go to.
    var checksums: [String: String] { get }
    /// Downloads the binary here, checks it, and puts it on the host (`progress` gets each step).
    func copy(_ copy: ServerCopy, to host: HostConfig, progress: @escaping @Sendable (String) -> Void) async throws
    /// `runner` is what the check found; a host's Server Command is run instead, as it is.
    func connectCommand(for host: HostConfig, runner: ServerRunner?) -> (executable: String, arguments: [String])
}

/// The real hosts: this Mac, and SSH destinations through the system's `ssh`. Everything runs under
/// the user's login shell, so PATH (the first `npx`, the first `claude`) matches their terminal.
public struct HostBootstrapper: ServerProvisioning {
    public enum BootstrapError: LocalizedError {
        case command(String, String)
        case download(String)

        public var errorDescription: String? {
            switch self {
            case .command(let cmd, let err): return "\(cmd) failed: \(err)"
            case .download(let reason): return reason
            }
        }
    }

    /// Each platform's binary's SHA-256: the pinned ones, or a test's.
    public let checksums: [String: String]

    public init(checksums: [String: String] = ServerRelease.checksums) {
        self.checksums = checksums
    }

    static var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// `command` under the host's login shell. Over SSH it's in single quotes, so it has none.
    static func underLoginShell(_ command: String, on host: HostConfig) -> (executable: String, arguments: [String]) {
        switch host.kind {
        case .local: return (loginShell, ["-lc", command])
        case .ssh(let dest):
            return ("/usr/bin/ssh", sshOptions + sharedConnectionOptions() + [dest, "exec \"$SHELL\" -lc '\(command)'"])
        }
    }

    public func connectCommand(for host: HostConfig, runner: ServerRunner?) -> (executable: String, arguments: [String]) {
        if let custom = host.serverCommand, !custom.isEmpty {
            switch host.kind {
            case .local: return (Self.loginShell, ["-lc", custom])
            case .ssh(let dest): return ("/usr/bin/ssh", Self.sshOptions + Self.sharedConnectionOptions() + [dest, custom])
            }
        }
        let command = runner == .copied ? "\(ServerRelease.copiedPath()) connect" : ServerRelease.npxCommand()
        return Self.underLoginShell("exec \(command)", on: host)
    }

    /// One command, in any login shell (sh, bash, zsh or fish): the system, the first `npx`'s Node.js,
    /// and a copied server's version. `true` so a host with neither still answers.
    static let probeCommand = "echo tether-probe; uname -sm; command -v npx >/dev/null && node --version; "
        + "\(ServerRelease.copiedPath()) version --json 2>/dev/null; true"

    public func probe(_ host: HostConfig) async throws -> ServerProbe {
        let command = Self.underLoginShell(Self.probeCommand, on: host)
        return try Self.parseProbe(try await Self.run(command.executable, command.arguments))
    }

    /// The probe's lines after its marker, whatever a login script printed before it.
    static func parseProbe(_ output: String) throws -> ServerProbe {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let marker = lines.lastIndex(of: "tether-probe"), marker + 1 < lines.count else {
            throw BootstrapError.command("The check", "no answer")
        }
        let rest = lines[(marker + 2)...]
        let node = rest.first { $0.wholeMatch(of: /v\d+(\.\d+)*/) != nil }.map { String($0.dropFirst()) }
        return ServerProbe(platform: platform(fromUname: lines[marker + 1]), node: node,
                           copied: installedServer(rest.joined(separator: "\n")))
    }

    /// `tether version --json`'s object, whatever a login script printed around it.
    static func installedServer(_ output: String) -> InstalledServer? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(InstalledServer.self, from: Data(output[start...end].utf8))
    }

    public func copy(_ copy: ServerCopy, to host: HostConfig, progress: @escaping @Sendable (String) -> Void) async throws {
        let binary = try await download(copy, progress: progress)
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        switch host.kind {
        case .local:
            try Self.place(binary, version: copy.version,
                           in: URL(filePath: NSString(string: ServerRelease.directory).expandingTildeInPath))
        case .ssh(let dest):
            let ssh = Self.sshOptions + Self.sharedConnectionOptions()
            let file = ServerRelease.copiedPath(version: copy.version)
            progress("Installing it on \(dest)")
            _ = try await Self.run("/usr/bin/ssh", ssh + [dest, "mkdir -p \(ServerRelease.directory)"])
            _ = try await Self.run("/usr/bin/scp", ["-q", "-o", "BatchMode=yes"] + Self.sharedConnectionOptions()
                                   + [binary.path, "\(dest):\(file.dropFirst(2)).part"])
            // Put in place whole, then the other versions cleared away: one a daemon is still
            // running from stays on disk until it exits.
            _ = try await Self.run("/usr/bin/ssh", ssh + [dest, "chmod 755 \(file).part && mv -f \(file).part \(file) && "
                                   + "find \(ServerRelease.directory) -maxdepth 1 -name 'tether*' ! -name tether-\(copy.version) -delete"])
        }
        progress("Installed Tether \(copy.version)")
    }

    /// The release's binary, downloaded to a folder of its own and checked against the checksum
    /// this app was built with.
    func download(_ copy: ServerCopy, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let name = ServerRelease.binaryName(version: copy.version, platform: copy.platform)
        guard let expected = checksums[copy.platform] else {
            throw BootstrapError.download("There’s no Tether \(copy.version) for \(copy.platform).")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "tether-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            progress("Downloading Tether \(copy.version) for \(copy.platform)")
            let binary = try await Self.download(ServerRelease.url(name, version: copy.version), to: folder.appending(path: name))
            progress("Checking it")
            guard try Self.sha256(of: binary) == expected else {
                throw BootstrapError.download("\(name) doesn’t match the checksum this app has for it.")
            }
            return binary
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Puts a checked binary in `folder` as `tether-<version>`, whole, and clears the other versions
    /// away.
    static func place(_ binary: URL, version: String, in folder: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appending(path: "tether-\(version).part")
        try? files.removeItem(at: part)
        try files.copyItem(at: binary, to: part)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: part.path)
        let destination = folder.appending(path: "tether-\(version)")
        _ = try files.replaceItemAt(destination, withItemAt: part)
        for name in try files.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("tether") && name != "tether-\(version)" {
            try? files.removeItem(at: folder.appending(path: name))
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

    /// `darwin-arm64`, `linux-x64` and so on, from `uname -sm`; nil for a system with no build.
    static func platform(fromUname s: String) -> String? {
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let os = parts[0] == "Darwin" ? "darwin" : parts[0] == "Linux" ? "linux" : ""
        let arch: String
        switch parts[1] {
        case "arm64", "aarch64": arch = "arm64"
        case "x86_64", "amd64": arch = "x64"
        default: arch = ""
        }
        guard !os.isEmpty, !arch.isEmpty else { return nil }
        return "\(os)-\(arch)"
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

    /// A release file, to a place of its own.
    static func download(_ url: URL, to destination: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BootstrapError.download("Couldn’t download \(url.lastPathComponent) (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func data(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BootstrapError.download("Couldn’t download \(url.lastPathComponent) (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return data
    }

    /// The file's SHA-256 in lowercase hex, read a megabyte at a time: a binary is about 100 MB.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
