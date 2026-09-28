import Foundation

/// A `tether://` link: what reaches the app from outside a window — a notification, the Dock
/// menu, Shortcuts — opened as a URL, so SwiftUI routes it to a window (`handlesExternalEvents`):
/// the one already showing the chat, else any open window, else a new one.
public enum TetherLink: Equatable, Sendable {
    /// A chat on a host.
    case chat(host: UUID, thread: String)
    /// New Chat, on `host` (the window's own when nil), in `folder` if given, with `prompt` in the
    /// field — or sent, given a token from `authorizeSend()`.
    case newChat(host: UUID? = nil, folder: String? = nil, prompt: String? = nil, sendToken: UUID? = nil)

    public static let scheme = "tether"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .chat(let host, let thread):
            c.host = "chat"
            c.queryItems = [URLQueryItem(name: "host", value: host.uuidString), URLQueryItem(name: "thread", value: thread)]
        case .newChat(let host, let folder, let prompt, let sendToken):
            c.host = "new-chat"
            c.queryItems = [host.map { URLQueryItem(name: "host", value: $0.uuidString) },
                            folder.map { URLQueryItem(name: "directory", value: $0) },
                            prompt.map { URLQueryItem(name: "prompt", value: $0) },
                            sendToken.map { URLQueryItem(name: "send", value: $0.uuidString) }].compactMap { $0 }
        }
        return c.url!
    }

    public init?(_ url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == Self.scheme else { return nil }
        let query = Dictionary((c.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { a, _ in a })
        switch c.host {
        case "chat":
            guard let host = query["host"].flatMap(UUID.init(uuidString:)), let thread = query["thread"] else { return nil }
            self = .chat(host: host, thread: thread)
        case "new-chat":
            self = .newChat(host: query["host"].flatMap(UUID.init(uuidString:)), folder: query["directory"],
                            prompt: query["prompt"], sendToken: query["send"].flatMap(UUID.init(uuidString:)))
        default:
            return nil
        }
    }

    /// Tokens for links that send their prompt, each good once and known only to this process. Any
    /// app or web page can open a `tether://` link; one of theirs can fill in New Chat but never
    /// start a turn.
    @MainActor private static var sendTokens: Set<UUID> = []

    /// A token for one link that sends its prompt (Shortcuts' Start a Chat, from this process).
    @MainActor public static func authorizeSend() -> UUID {
        let token = UUID()
        sendTokens.insert(token)
        return token
    }

    /// Whether `token` came from `authorizeSend()` and hasn't been used.
    @MainActor static func redeem(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return sendTokens.remove(token) != nil
    }

    /// The string a window showing this chat prefers links by.
    static func preference(host: UUID, thread: String?) -> Set<String> {
        guard let thread else { return [] }
        return [TetherLink.chat(host: host, thread: thread).url.absoluteString]
    }
}
