import Foundation

/// A machine running (or able to run) a Tether server.
public struct HostConfig: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case local
        /// An `ssh` destination (alias from ~/.ssh/config, or user@host).
        case ssh(destination: String)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Environment overrides for Claude on this host, e.g. AWS_PROFILE / AWS_REGION for Bedrock.
    public var env: [String: String]
    /// Developer override: a shell command that speaks Tether JSONL on stdio (skips install).
    public var serverCommand: String?

    public init(id: UUID = UUID(), name: String, kind: Kind, env: [String: String] = [:], serverCommand: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.env = env
        self.serverCommand = serverCommand
    }

    public static let local = HostConfig(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "This Mac", kind: .local)

    public var isLocal: Bool { if case .local = kind { return true }; return false }
    public var sshDestination: String? { if case .ssh(let d) = kind { return d }; return nil }
}

/// Reads `Host` aliases from ~/.ssh/config (skips wildcard patterns), following Include directives.
public enum SSHConfig {
    public static func hostAliases(path: String = NSString(string: "~/.ssh/config").expandingTildeInPath) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func read(_ p: String, depth: Int) {
            guard depth < 5, let text = try? String(contentsOfFile: p, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "host" {
                    for alias in value.split(separator: " ") where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                        if seen.insert(String(alias)).inserted { out.append(String(alias)) }
                    }
                } else if key == "include" {
                    for inc in value.split(separator: " ") {
                        var incPath = NSString(string: String(inc)).expandingTildeInPath
                        if !incPath.hasPrefix("/") { incPath = NSString(string: "~/.ssh/\(inc)").expandingTildeInPath }
                        for match in glob(incPath) { read(match, depth: depth + 1) }
                    }
                }
            }
        }
        read(path, depth: 0)
        return out
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].flatMap { String(cString: $0) } }
    }
}
