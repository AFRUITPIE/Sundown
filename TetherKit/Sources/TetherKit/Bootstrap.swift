import Foundation

/// The Tether server this build of the app runs: tether-server's npm package, at the version its
/// protocol package is pinned to. Every host has Node.js 18 or later, and runs it with `npx`, so
/// nothing is installed beside npm's cache.
public enum ServerRelease {
    /// Moves with the protocol package's pin, which is the server this app was built against.
    public static let version = "0.5.8"

    /// What connecting runs on a host. Not `--prefer-offline`: npm then trusts a cached list of the
    /// package's versions, which a new app's version isn't in yet.
    static let npxCommand = "npx --yes tether-server@\(version) connect"
}

/// Builds the command that connects to a host's Tether daemon: this Mac, or an SSH destination
/// through the system's `ssh`. Under the user's login shell, so PATH (the first `npx`, the first
/// `claude`) matches their terminal. A host's Server Command is run instead, as it is.
public struct HostBootstrapper: Sendable {
    public init() {}

    static var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    public func connectCommand(for host: HostConfig) -> (executable: String, arguments: [String]) {
        let ssh = Self.sshOptions + Self.sharedConnectionOptions()
        if let custom = host.serverCommand, !custom.isEmpty {
            switch host.kind {
            case .local: return (Self.loginShell, ["-lc", custom])
            case .ssh(let dest): return ("/usr/bin/ssh", ssh + [dest, custom])
            }
        }
        switch host.kind {
        case .local: return (Self.loginShell, ["-lc", "exec \(ServerRelease.npxCommand)"])
        case .ssh(let dest): return ("/usr/bin/ssh", ssh + [dest, "exec \"$SHELL\" -lc 'exec \(ServerRelease.npxCommand)'"])
        }
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
