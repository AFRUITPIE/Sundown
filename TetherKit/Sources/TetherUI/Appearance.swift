import SwiftUI
import TetherKit

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
    public var openFilesWith: FileEditor = .defaultApp

    // Advanced
    public var toolCalls: ToolCallDisplay = .summarized
    public var sidebar: SidebarStyle = .chats
    public var inspector: InspectorPlacement = .panel

    public init() {}

    /// Where Tasks, Session, MCP and Changes are shown.
    public enum InspectorPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A column beside the chat, attached to the split view.
        case column
        /// A floating panel above the windows, showing the front window's chat. The chat window never
        /// changes width.
        case panel
        /// A drawer under the chat, whose height changes rather than the transcript's width.
        case drawer
        /// A card over the chat's trailing edge; the transcript underneath keeps its width.
        case overlay
        public var id: Self { self }
        var label: String {
            switch self {
            case .column: "Beside the Chat"
            case .panel: "Floating Panel"
            case .drawer: "Drawer"
            case .overlay: "Over the Chat"
            }
        }
    }

    /// What the sidebar lists, and how.
    public enum SidebarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Pinned chats, then the rest grouped by date or folder (View ▸ Group By).
        case chats
        /// What needs you, then every chat by day, each with its latest reply, as Mail lists mail.
        case activity
        public var id: Self { self }
        var label: String {
            switch self {
            case .chats: "Chats"
            case .activity: "Activity"
            }
        }
    }

    /// How finished tool calls read in the transcript.
    public enum ToolCallDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Each run of finished calls folds into one line that says what they did.
        case summarized
        /// A finished turn's work folds into one "Worked for" line above its last message.
        case workedFor
        /// One line per call, nothing folded.
        case everyCall
        public var id: Self { self }
        var label: String {
            switch self {
            case .summarized: "Summarized"
            case .workedFor: "Worked For"
            case .everyCall: "Every Call"
            }
        }

        var folding: TranscriptFolding {
            switch self {
            case .summarized: .summarized
            case .workedFor: .workedFor
            case .everyCall: .everyCall
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

    /// Where Open sends a file from a chat on this Mac. The editors are the ones people use for
    /// code; Settings lists those that are installed (`OpenFiles.swift`).
    public enum FileEditor: String, Codable, CaseIterable, Identifiable, Sendable {
        case defaultApp, xcode, visualStudioCode, cursor, zed, nova, bbedit, sublimeText
        public var id: Self { self }
        var label: String {
            switch self {
            case .defaultApp: "Default App"
            case .xcode: "Xcode"
            case .visualStudioCode: "Visual Studio Code"
            case .cursor: "Cursor"
            case .zed: "Zed"
            case .nova: "Nova"
            case .bbedit: "BBEdit"
            case .sublimeText: "Sublime Text"
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
        openFilesWith = value(.openFilesWith, d.openFilesWith)
        toolCalls = value(.toolCalls, d.toolCalls)
        sidebar = value(.sidebar, d.sidebar)
        inspector = value(.inspector, d.inspector)
    }
}

extension EnvironmentValues {
    /// The app's settings that views read, set once at each window's root.
    @Entry public var appearance = Appearance()
}
