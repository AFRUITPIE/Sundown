import SwiftUI

/// The settings that change how the app behaves or is laid out: a few in Settings ▸ General, and
/// in Settings ▸ Advanced the layouts still being compared, each switchable in the running app.
/// One value in the environment, compared as a whole, so a view redraws only when a setting changes.
/// Persisted by `AppModel`; a store missing a key (an older build's) takes that key's default, and
/// keys a newer build dropped are ignored.
public struct Appearance: Codable, Equatable, Sendable {
    // General
    public var wrapCode = true
    public var sendShortcut: SendShortcut = .returnKey
    public var newChatFolder: NewChatFolder = .recent
    public var worktreeByDefault = false
    public var sessionTools = false
    /// Off by default, as in Claude Code: Bypass Permissions has to be asked for.
    public var offerBypass = false

    // Advanced
    public var toolCalls: ToolCallDisplay = .summarized

    public init() {}

    /// How finished tool calls read in the transcript.
    public enum ToolCallDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Each run of finished calls folds into one line that says what they did.
        case summarized
        /// One line per call, nothing folded.
        case everyCall
        public var id: Self { self }
        var label: String {
            switch self {
            case .summarized: "Summarized"
            case .everyCall: "Every Call"
            }
        }
    }

    public enum SendShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Return sends; Shift-Return (or Option-Return) starts a new line.
        case returnKey
        /// Command-Return sends; Return starts a new line.
        case commandReturn
        public var id: Self { self }
        var label: String {
            switch self {
            case .returnKey: "Return"
            case .commandReturn: "Command-Return"
            }
        }
    }

    public enum NewChatFolder: String, Codable, CaseIterable, Identifiable, Sendable {
        case recent, ask
        public var id: Self { self }
        var label: String {
            switch self {
            case .recent: "Most Recent"
            case .ask: "Choose Each Time"
            }
        }
    }

    // Each key optional, so a store from before a setting existed keeps its other choices.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = Appearance()
        wrapCode = value(.wrapCode, d.wrapCode)
        sendShortcut = value(.sendShortcut, d.sendShortcut)
        newChatFolder = value(.newChatFolder, d.newChatFolder)
        worktreeByDefault = value(.worktreeByDefault, d.worktreeByDefault)
        sessionTools = value(.sessionTools, d.sessionTools)
        offerBypass = value(.offerBypass, d.offerBypass)
        toolCalls = value(.toolCalls, d.toolCalls)
    }
}

extension EnvironmentValues {
    /// The app's settings that views read, set once at each window's root.
    @Entry public var appearance = Appearance()
}
