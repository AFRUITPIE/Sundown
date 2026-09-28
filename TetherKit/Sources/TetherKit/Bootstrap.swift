import CryptoKit
import Foundation
import Synchronization

/// What the app does with a host's server before connecting: looks at what's installed, installs
/// or updates it when the user says to, and builds the command that connects. A seam, so the UI
/// tests' fixture hosts can be missing a server, or have one too old or too new.
public protocol ServerProvisioning: Sendable {
    func probe(_ host: HostConfig) async throws -> ServerProbe
    /// The offer's download size, when the release answers; asked while the offer is on screen.
    func downloadSize(of offer: ServerOffer) async -> Int64?
    /// Runs the offer's command on the host (`progress` gets its lines as they come), or, when the
    /// host can't download it, downloads and checks it here and copies it over.
    func install(_ offer: ServerOffer, on host: HostConfig, progress: @escaping @Sendable (String) -> Void) async throws
    func connectCommand(for host: HostConfig) -> (executable: String, arguments: [String])
}

/// The real hosts: this Mac, and SSH destinations through the system's `ssh`. Nothing is bundled:
/// a host has its server in `~/.tether/bin`, installed and updated from tether-server's releases.
public struct HostBootstrapper: ServerProvisioning {
    public enum BootstrapError: LocalizedError {
        case unsupportedPlatform(String)
        case command(String, String)
        case install(String)
        case download(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlatform(let p): return "No Tether server build for \(p)."
            case .command(let cmd, let err): return "\(cmd) failed: \(err)"
            case .install(let reason), .download(let reason): return reason
            }
        }
    }

    public init() {}

    public func connectCommand(for host: HostConfig) -> (executable: String, arguments: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let ssh = Self.sshOptions + Self.sharedConnectionOptions()
        if let custom = host.serverCommand, !custom.isEmpty {
            switch host.kind {
            case .local: return (shell, ["-lc", custom])
            case .ssh(let dest): return ("/usr/bin/ssh", ssh + [dest, custom])
            }
        }
        // Under the user's login shell, so PATH (and the first `claude`) match their terminal.
        switch host.kind {
        case .local:
            return (shell, ["-lc", "exec \(ServerRelease.installedPath) connect"])
        case .ssh(let dest):
            return ("/usr/bin/ssh", ssh + [dest, "exec \"$SHELL\" -lc 'exec \(ServerRelease.installedPath) connect'"])
        }
    }

    public func probe(_ host: HostConfig) async throws -> ServerProbe {
        switch host.kind {
        case .local:
            let path = NSString(string: ServerRelease.installedPath).expandingTildeInPath
            var installed: InstalledServer?
            if FileManager.default.isExecutableFile(atPath: path) {
                installed = (try? await Self.run(path, ["version", "--json"])).flatMap(Self.installedServer)
            } else {
                let folder = (path as NSString).deletingLastPathComponent
                installed = Self.earlierInstall((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            }
            return ServerProbe(platform: "darwin-\(Self.localArch)", installed: installed)
        case .ssh(let dest):
            // One login for all of it; `true` so a host without the server still answers.
            let output = try await Self.run("/usr/bin/ssh", Self.sshOptions + Self.sharedConnectionOptions()
                                            + [dest, "uname -sm; \(ServerRelease.installedPath) version --json 2>/dev/null || ls ~/.tether/bin 2>/dev/null; true"])
            let lines = output.split(separator: "\n", maxSplits: 1)
            guard let uname = lines.first else { throw BootstrapError.command("ssh", "no output from \(dest)") }
            let rest = lines.count > 1 ? String(lines[1]) : ""
            return ServerProbe(platform: try Self.platform(fromUname: String(uname)),
                               installed: Self.installedServer(rest)
                                   ?? Self.earlierInstall(rest.split(whereSeparator: \.isNewline).map(String.init)))
        }
    }

    /// A server an earlier version of this app put in `~/.tether/bin` (`tether-<version>`, no
    /// `tether` link to it): the newest release there, as too old for this app, so the host is
    /// offered an update, which links it and clears the rest away.
    static func earlierInstall(_ names: [String]) -> InstalledServer? {
        let versions = names.compactMap { name -> String? in
            guard name.hasPrefix("tether-") else { return nil }
            let version = String(name.dropFirst("tether-".count))
            return version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil ? version : nil
        }
        guard let newest = versions.max(by: { ServerVersion($0) < ServerVersion($1) }) else { return nil }
        return InstalledServer(version: newest, protocolVersion: 0, minClientProtocol: 0)
    }

    /// `tether version --json`'s object, whatever a login script printed around it.
    static func installedServer(_ output: String) -> InstalledServer? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(InstalledServer.self, from: Data(output[start...end].utf8))
    }

    public func downloadSize(of offer: ServerOffer) async -> Int64? {
        var request = URLRequest(url: ServerRelease.url(ServerRelease.binaryName(version: offer.version, platform: offer.platform),
                                                        version: offer.version))
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength
    }

    public func install(_ offer: ServerOffer, on host: HostConfig, progress: @escaping @Sendable (String) -> Void) async throws {
        do {
            switch host.kind {
            case .local:
                try await Self.stream("/bin/sh", ["-c", offer.command], progress: progress)
            case .ssh(let dest):
                try await Self.stream("/usr/bin/ssh", Self.sshOptions + Self.sharedConnectionOptions() + [dest, offer.command],
                                      progress: progress)
            }
        } catch {
            // A host that can't reach the releases (no way out, a proxy it doesn't know) gets them
            // from this Mac. If that fails too, the host's own reason is the one to show.
            progress("\(host.name) couldn’t install it (\(error.localizedDescription)); downloading it on this Mac")
            do {
                try await installFromThisMac(offer, on: host, progress: progress)
            } catch let fallback {
                progress("That failed too: \(fallback.localizedDescription)")
                throw error
            }
        }
    }

    /// Downloads the binary and install.sh here, checks the binary against the release's
    /// SHA256SUMS, and has install.sh put that file in place on the host (`TETHER_BINARY`).
    func installFromThisMac(_ offer: ServerOffer, on host: HostConfig, progress: @escaping @Sendable (String) -> Void) async throws {
        let name = ServerRelease.binaryName(version: offer.version, platform: offer.platform)
        let folder = FileManager.default.temporaryDirectory.appending(path: "tether-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        progress("Downloading Tether \(offer.version) for \(offer.platform)")
        let binary = try await Self.download(ServerRelease.url(name, version: offer.version), to: folder.appending(path: name))
        let sums = String(decoding: try await Self.data(ServerRelease.url("SHA256SUMS", version: offer.version)), as: UTF8.self)
        let script = try await Self.data(ServerRelease.url("install.sh", version: offer.version))
        progress("Verifying")
        guard let expected = ReleaseChecksums.digest(of: name, in: sums) else {
            throw BootstrapError.download("The release doesn’t list a checksum for \(name).")
        }
        guard try Self.sha256(of: binary) == expected else {
            throw BootstrapError.download("\(name) doesn’t match its checksum.")
        }
        switch host.kind {
        case .local:
            // The folder's name is a UUID: nothing in the path needs quoting.
            let preamble = "TETHER_BINARY='\(binary.path)'\nexport TETHER_BINARY\n"
            try await Self.stream("/bin/sh", ["-s"], input: Data(preamble.utf8) + script, progress: progress)
        case .ssh(let dest):
            let ssh = Self.sshOptions + Self.sharedConnectionOptions()
            let upload = ".tether/bin/\(name).upload"
            progress("Copying it to \(dest)")
            _ = try await Self.run("/usr/bin/ssh", ssh + [dest, "mkdir -p ~/.tether/bin"])
            _ = try await Self.run("/usr/bin/scp", ["-q", "-o", "BatchMode=yes"] + Self.sharedConnectionOptions()
                                   + [binary.path, "\(dest):\(upload)"])
            // `sh -s` reads the script from here, so the host's login shell (fish, say) only runs `sh`.
            let preamble = "TETHER_BINARY=\"$HOME/\(upload)\"\nexport TETHER_BINARY\n"
            try await Self.stream("/usr/bin/ssh", ssh + [dest, "sh -s"], input: Data(preamble.utf8) + script, progress: progress)
            _ = try? await Self.run("/usr/bin/ssh", ssh + [dest, "rm -f ~/\(upload)"])
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

    /// Runs a command, handing each line it prints to `progress` as it comes (install.sh's
    /// `tether-install: ` prefix taken off), with `input` on its standard input. A failure says
    /// install.sh's own reason when it gave one.
    static func stream(_ exe: String, _ args: [String], input: Data? = nil,
                       progress: @escaping @Sendable (String) -> Void) async throws {
        let prefix = "tether-install: "
        let tidy: @Sendable (Substring) -> String = { line in
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : String(line)
        }
        let pending = Mutex(Data())
        let errors = Mutex(Data())
        let emit: @Sendable (Data, Bool) -> Void = { chunk, final in
            let lines: [Substring] = pending.withLock { buffer in
                buffer.append(chunk)
                var text = String(decoding: buffer, as: UTF8.self)
                if !final, let last = text.lastIndex(of: "\n") {
                    buffer = Data(text[text.index(after: last)...].utf8)
                    text = String(text[..<last])
                } else if !final {
                    return []
                } else {
                    buffer = Data()
                }
                return text.split(whereSeparator: \.isNewline)
            }
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty { progress(tidy(line)) }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            let out = Pipe(), err = Pipe(), inPipe = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
            out.fileHandleForReading.readabilityHandler = { handle in emit(handle.availableData, false) }
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                errors.withLock { $0.append(chunk) }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                emit(out.fileHandleForReading.readDataToEndOfFile(), true)
                let rest = err.fileHandleForReading.readDataToEndOfFile()
                let stderr = errors.withLock { String(decoding: $0 + rest, as: UTF8.self) }
                guard proc.terminationStatus != 0 else { return cont.resume() }
                let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
                let reason = lines.last { $0.hasPrefix(prefix + "error: ") }.map { String($0.dropFirst((prefix + "error: ").count)) }
                    ?? lines.last?.trimmingCharacters(in: .whitespaces)
                    ?? "exit \(proc.terminationStatus)"
                cont.resume(throwing: BootstrapError.install(reason))
            }
            do {
                try process.run()
                if let input {
                    inPipe.fileHandleForWriting.write(input)
                    try? inPipe.fileHandleForWriting.close()
                }
            } catch {
                cont.resume(throwing: error)
            }
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
