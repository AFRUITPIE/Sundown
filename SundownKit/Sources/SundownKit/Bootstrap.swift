import Foundation
import Subprocess
import System

/// The Sundown server this build of the app runs: tether-server's npm package, at the version its
/// protocol package is pinned to. Every host has Node.js 18 or later, and runs it with `npx`, so
/// nothing is installed beside npm's cache.
public enum ServerRelease {
    /// Moves with the protocol package's pin, which is the server this app was built against.
    public static let version = "0.5.22"

    /// What connecting runs on a host. Not `--prefer-offline`: npm then trusts a cached list of the
    /// package's versions, which a new app's version isn't in yet.
    static let npxCommand = "npx --yes tether-server@\(version) connect"
}

/// Builds the command that connects to a host's Sundown daemon: this Mac, or an SSH destination
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

    static let pathMarker = "__SUNDOWN_PATH__"

    /// This app's environment without what a Claude Code session puts in its children's:
    /// `CLAUDECODE` and every `CLAUDE_…` variable. Sundown opened from a terminal inside Claude Code
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
        let path = folder + "/sundown-%C"
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

/// One short command, its output gathered until it has exited, `done` says it has said enough (a
/// shell can leave a child holding its output open), or the timeout; then it's stopped.
struct ShellRun: Sendable {
    private let configuration: Configuration

    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        var options = PlatformOptions()
        // Asked to stop, then made to.
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(1))]
        configuration = Configuration(executable: .path(FilePath(executable)), arguments: Arguments(arguments),
                                      environment: environment.map(Environment.exactly) ?? .inherit,
                                      platformOptions: options)
    }

    /// `status` is nil when it hadn't exited, or never started.
    func result(timeout: Duration, done: @escaping @Sendable (String) -> Bool) async -> (status: Int32?, output: String, errors: String) {
        let gathered = await withTaskGroup(of: Ending.self, returning: Gathered?.self) { group in
            group.addTask { .ran(await gather(done)) }
            group.addTask {
                // Cancelled once the command has finished; at the deadline, the command is.
                try? await Task.sleep(for: timeout)
                return .deadline
            }
            let first = await group.next()!
            group.cancelAll()
            guard case .ran(let gathered) = first else {
                // Cancelling the run stopped the command, which leaves what it had said by then.
                guard case .ran(var gathered?) = await group.next()! else { return nil }
                gathered.status = nil
                return gathered
            }
            return gathered
        }
        return (gathered?.status, String(decoding: gathered?.output ?? Data(), as: UTF8.self),
                String(decoding: gathered?.errors ?? Data(), as: UTF8.self))
    }

    private enum Ending: Sendable {
        case ran(Gathered?)
        case deadline
    }

    private struct Gathered: Sendable {
        var status: Int32?
        var output: Data
        var errors: Data
    }

    /// Runs the command to the end of its output, or until `done`; nil when it couldn't start.
    private func gather(_ done: @escaping @Sendable (String) -> Bool) async -> Gathered? {
        let result = try? await run(configuration, input: .none, output: .sequence, error: .sequence) { execution in
            async let errors = Self.read(execution.standardError, upTo: 64_000)
            var output = Data()
            var saidEnough = false
            do {
                for try await chunk in execution.standardOutput where output.count < 1_000_000 {
                    chunk.withUnsafeBytes { output.append($0.assumingMemoryBound(to: UInt8.self)) }
                    if done(String(decoding: output, as: UTF8.self)) { saidEnough = true; break }
                }
            } catch {}
            if saidEnough { await execution.teardown(using: configuration.platformOptions.teardownSequence) }
            return (output, await errors, saidEnough)
        }
        guard let result else { return nil }
        let (output, errors, saidEnough) = result.closureResult
        return Gathered(status: saidEnough ? nil : result.terminationStatus.code, output: output, errors: errors)
    }

    /// Everything the stream says, keeping at most `limit` bytes.
    private static func read(_ stream: SubprocessOutputSequence, upTo limit: Int) async -> Data {
        var data = Data()
        do {
            for try await chunk in stream where data.count < limit {
                chunk.withUnsafeBytes { data.append($0.assumingMemoryBound(to: UInt8.self)) }
            }
        } catch {}
        return data
    }
}

extension Environment {
    /// This environment and nothing else.
    static func exactly(_ variables: [String: String]) -> Environment {
        .custom(Dictionary(uniqueKeysWithValues: variables.compactMap { name, value in Key(rawValue: name).map { ($0, value) } }))
    }
}

extension TerminationStatus {
    /// The exit status, or the signal that ended it, as `Process.terminationStatus` says it.
    var code: Int32 {
        switch self {
        case .exited(let code), .signaled(let code): code
        }
    }
}
