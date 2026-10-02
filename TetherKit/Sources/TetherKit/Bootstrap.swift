import Foundation

/// The Tether server this build of the app runs: tether-server's npm package, at the version its
/// protocol package is pinned to. Every host has Node.js 18 or later, and runs it with `npx`, so
/// nothing is installed beside npm's cache.
public enum ServerRelease {
    /// Moves with the protocol package's pin, which is the server this app was built against.
    public static let version = "0.5.13"

    /// What connecting runs on a host. Not `--prefer-offline`: npm then trusts a cached list of the
    /// package's versions, which a new app's version isn't in yet.
    static let npxCommand = "npx --yes tether-server@\(version) connect"
}

/// Builds the command that connects to a host's Tether daemon: this Mac, or an SSH destination
/// through the system's `ssh`. Under the user's login shell, with the PATH their terminal has (the
/// first `npx`, the first `claude`), which `shellPathCommand` reads first. A host's Server Command
/// is run instead, as it is.
public struct HostBootstrapper: Sendable {
    public init() {}

    static var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// `path` is the one the host's interactive shell has (`shellPathCommand`), given to `npx` and
    /// so to the daemon it starts. Nil, or one that can't be put in double quotes as it is, leaves
    /// the login shell's.
    public func connectCommand(for host: HostConfig, path: String? = nil) -> (executable: String, arguments: [String]) {
        let ssh = Self.sshOptions + Self.sharedConnectionOptions()
        if let custom = host.serverCommand, !custom.isEmpty {
            switch host.kind {
            case .local: return (Self.loginShell, ["-lc", custom])
            case .ssh(let dest): return ("/usr/bin/ssh", ssh + [dest, custom])
            }
        }
        // `env`, not `PATH=… npx`: the same in sh, zsh, bash and fish.
        let npx = path.flatMap(Self.quotable).map { "env PATH=\"\($0)\" \(ServerRelease.npxCommand)" } ?? ServerRelease.npxCommand
        switch host.kind {
        case .local: return (Self.loginShell, ["-lc", "exec \(npx)"])
        case .ssh(let dest): return ("/usr/bin/ssh", ssh + [dest, "exec \"$SHELL\" -lc 'exec \(npx)'"])
        }
    }

    /// A PATH that means the same inside double quotes in every shell, nested in single quotes.
    static func quotable(_ path: String) -> String? {
        path.isEmpty || path.contains(where: { "\"'$`\\\n".contains($0) }) ? nil : path
    }

    /// Asks the host's shell, interactive, for its PATH: what people set in `.zshrc`, `.bashrc` or
    /// `config.fish` (nvm, mise, a `claude` wrapper) is read only by an interactive shell, and the
    /// login shell `connectCommand` runs isn't one, since whatever an rc file prints would land in
    /// the JSON-RPC stream. Here it can print what it likes: the PATH is between two markers.
    func shellPathCommand(for host: HostConfig) -> (executable: String, arguments: [String]) {
        let probe = "printf %s \(Self.pathMarker); printenv PATH; printf %s \(Self.pathMarker)"
        switch host.kind {
        case .local: return (Self.loginShell, ["-ilc", probe])
        case .ssh(let dest):
            let ssh = Self.sshOptions + Self.sharedConnectionOptions()
            return ("/usr/bin/ssh", ssh + [dest, "exec \"$SHELL\" -ilc '\(probe)'"])
        }
    }

    static let pathMarker = "__TETHER_PATH__"

    /// This app's environment without what a Claude Code session puts in its children's:
    /// `CLAUDECODE` and every `CLAUDE_…` variable. Tether opened from a terminal inside Claude Code
    /// (or Claude's desktop app) inherits them, the server it starts passes them on, and Claude
    /// Code then runs each chat as that host's child session: as a desktop one it named chats
    /// after their first prompt and never made a title of its own. What the person sets for Claude
    /// Code in their shell's files the login shell sets again; an SSH host never gets these.
    static func serverEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { name, _ in name != "CLAUDECODE" && !name.hasPrefix("CLAUDE_") }
    }

    /// The PATH between the markers, once both have come.
    static func shellPath(in output: String) -> String? {
        let parts = output.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The host's interactive PATH (`shellPathCommand`), or nil when its shell didn't say within
    /// `timeout`: an rc file that waits for input, or one that `exec`s another shell. Throws only
    /// when `ssh` couldn't reach the host, which connecting would say again after as long a wait.
    func interactivePath(for host: HostConfig, timeout: Duration = .seconds(10)) async throws -> String? {
        let cmd = shellPathCommand(for: host)
        let run = ShellRun(executable: cmd.executable, arguments: cmd.arguments, environment: Self.serverEnvironment())
        let result = await run.result(timeout: timeout) { Self.shellPath(in: $0) != nil }
        if let path = Self.shellPath(in: result.output) { return path }
        if case .ssh = host.kind, result.status == 255 {
            throw TransportError.closed(exitCode: 255, stderr: result.errors)
        }
        return nil
    }

    /// A keepalive every 30 s, not 15: each wakes the radio on both ends, and a connection that died
    /// quietly is still noticed within two minutes.
    public static let sshOptions = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4", "-o", "ConnectTimeout=15"]

    /// One SSH connection per host, kept a minute after it's last used, so a reconnect isn't a
    /// login of its own (a TCP and SSH handshake, and the host's authentication). The socket goes in `~/.ssh`, private to the user. Nothing when that isn't
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
}

/// One short command, its output gathered until it has exited and closed its output, `done` says
/// it has said enough (a shell can leave a child holding its output open), or the timeout.
final class ShellRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var closed = false
    private var status: Int32?

    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
    }

    /// `status` is nil when it hadn't exited, or never started.
    func result(timeout: Duration, done: @escaping @Sendable (String) -> Bool) async -> (status: Int32?, output: String, errors: String) {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { h.readabilityHandler = nil; return }
            self.lock.withLock { if self.err.count < 64_000 { self.err.append(d) } }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            guard !d.isEmpty else {
                h.readabilityHandler = nil
                self.finish { $0.closed = true }
                return
            }
            let text = self.lock.withLock { () -> String? in
                guard self.out.count < 1_000_000 else { return nil }
                self.out.append(d)
                return String(decoding: self.out, as: UTF8.self)
            }
            if let text, done(text) { self.finish { $0.finished = true } }
        }
        process.terminationHandler = { [weak self] p in self?.finish { $0.status = p.terminationStatus } }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { continuation = c }
            do { try process.run() } catch { finish { $0.finished = true }; return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish { $0.finished = true }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return lock.withLock { (status, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
    }

    /// Records what happened, and resumes once it's done: `finished`, or exited with its output closed.
    private func finish(_ change: (ShellRun) -> Void) {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            change(self)
            guard finished || (closed && status != nil), let c = continuation else { return nil }
            continuation = nil
            finished = true
            return c
        }
        c?.resume()
    }
}
