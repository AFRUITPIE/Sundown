import SwiftUI

/// How the app looks and behaves, from Settings ▸ Appearance: the choices behind each pattern in
/// the transcript, tool calls, motion, composer and sidebar, so each can be tried against the
/// others. One value in the environment, compared as a whole, so a row redraws only when a setting
/// changes. Persisted by `AppModel`; a store missing a key (an older build's) takes its default.
public struct Appearance: Codable, Equatable, Sendable {
    // Transcript
    public var density: Density = .standard
    public var replyFont: ReplyFont = .system
    public var promptStyle: PromptStyle = .bubble
    public var timestamps: Timestamps = .never
    public var messageActions: MessageActions = .onHover
    public var wrapCode = true

    // Tool calls
    public var groupToolCalls = true
    public var toolIcons = false
    public var statusSide: Side = .trailing
    public var chevronSide: Side = .trailing
    public var showElapsed = true
    public var expandFailures = false

    // Motion
    public var fadeInText = true
    public var fadeInRows = true
    public var followMotion: FollowMotion = .glide
    public var showThinking = true
    public var turnSummary = false

    // Composer
    public var composerLayout: ComposerLayout = .messages
    public var sendShortcut: SendShortcut = .returnKey
    public var promptSuggestions = true
    public var contextRing = true
    public var composerLines = 12

    // Permissions
    public var offerBypass = true
    public var offerDontAsk = true

    // Sidebar
    public var rowDetail: RowDetail = .folder
    public var runningIndicator = true
    public var toolbarModelName = true
    public var newChatFolder: NewChatFolder = .recent
    public var toolCallVisibility: ToolCallVisibility = .all
    public var doubleClickOpensWindow = true
    public var showTips = true

    public init() {}

    public enum Density: String, Codable, CaseIterable, Identifiable, Sendable {
        case compact, standard, spacious
        public var id: Self { self }
        var label: String { rawValue.capitalized }
        /// Between rows of the transcript.
        var rowSpacing: CGFloat {
            switch self {
            case .compact: 8
            case .standard: 14
            case .spacious: 22
            }
        }
        /// Between a reply's paragraphs, as a multiple of the standard spacing.
        var blockScale: CGFloat {
            switch self {
            case .compact: 0.6
            case .standard: 1
            case .spacious: 1.4
            }
        }
    }

    public enum ReplyFont: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, serif, rounded, monospaced
        public var id: Self { self }
        var label: String {
            switch self {
            case .system: "System"
            case .serif: "Serif"
            case .rounded: "Rounded"
            case .monospaced: "Monospaced"
            }
        }
        var design: Font.Design {
            switch self {
            case .system: .default
            case .serif: .serif
            case .rounded: .rounded
            case .monospaced: .monospaced
            }
        }
    }

    public enum PromptStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A bubble at the trailing edge, as Messages draws what you sent.
        case bubble
        /// Full width, marked by a bar at the leading edge, like a reply's quote.
        case plain
        public var id: Self { self }
        var label: String {
            switch self {
            case .bubble: "Bubble"
            case .plain: "Plain"
            }
        }
    }

    public enum Timestamps: String, Codable, CaseIterable, Identifiable, Sendable {
        case never, onHover, always
        public var id: Self { self }
        var label: String {
            switch self {
            case .never: "Never"
            case .onHover: "On Hover"
            case .always: "Always"
            }
        }
    }

    public enum MessageActions: String, Codable, CaseIterable, Identifiable, Sendable {
        case onHover, contextMenu
        public var id: Self { self }
        var label: String {
            switch self {
            case .onHover: "On Hover and in the Context Menu"
            case .contextMenu: "In the Context Menu Only"
            }
        }
    }

    public enum Side: String, Codable, CaseIterable, Identifiable, Sendable {
        case leading, trailing
        public var id: Self { self }
        var label: String {
            switch self {
            case .leading: "Leading"
            case .trailing: "Trailing"
            }
        }
    }

    public enum FollowMotion: String, Codable, CaseIterable, Identifiable, Sendable {
        case glide, jump
        public var id: Self { self }
        var label: String {
            switch self {
            case .glide: "Glide"
            case .jump: "Jump"
            }
        }
    }

    public enum ComposerLayout: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A round + beside the field, and Send inside it, as Messages lays it out.
        case messages
        /// The + inside the field at its leading end.
        case inline
        /// No +: attach by dropping or pasting.
        case minimal
        public var id: Self { self }
        var label: String {
            switch self {
            case .messages: "Messages"
            case .inline: "Inline"
            case .minimal: "Minimal"
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
            case .recent: "The Most Recent Folder"
            case .ask: "No Folder Until I Choose One"
            }
        }
    }

    public enum ToolCallVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Every call, finished ones folded as Group Finished Calls says.
        case all
        /// Only calls still running or that went wrong: finished work is left out.
        case attention
        /// No calls at all: just the conversation.
        case none
        public var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .attention: "Only Running and Failed"
            case .none: "None"
            }
        }
    }

    public enum RowDetail: String, Codable, CaseIterable, Identifiable, Sendable {
        case titleOnly, folder, folderAndTime
        public var id: Self { self }
        var label: String {
            switch self {
            case .titleOnly: "Title Only"
            case .folder: "Title and Folder"
            case .folderAndTime: "Title, Folder and Time"
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
        density = value(.density, d.density)
        replyFont = value(.replyFont, d.replyFont)
        promptStyle = value(.promptStyle, d.promptStyle)
        timestamps = value(.timestamps, d.timestamps)
        messageActions = value(.messageActions, d.messageActions)
        wrapCode = value(.wrapCode, d.wrapCode)
        groupToolCalls = value(.groupToolCalls, d.groupToolCalls)
        toolIcons = value(.toolIcons, d.toolIcons)
        statusSide = value(.statusSide, d.statusSide)
        chevronSide = value(.chevronSide, d.chevronSide)
        showElapsed = value(.showElapsed, d.showElapsed)
        expandFailures = value(.expandFailures, d.expandFailures)
        fadeInText = value(.fadeInText, d.fadeInText)
        fadeInRows = value(.fadeInRows, d.fadeInRows)
        followMotion = value(.followMotion, d.followMotion)
        showThinking = value(.showThinking, d.showThinking)
        turnSummary = value(.turnSummary, d.turnSummary)
        composerLayout = value(.composerLayout, d.composerLayout)
        sendShortcut = value(.sendShortcut, d.sendShortcut)
        promptSuggestions = value(.promptSuggestions, d.promptSuggestions)
        contextRing = value(.contextRing, d.contextRing)
        composerLines = value(.composerLines, d.composerLines)
        offerBypass = value(.offerBypass, d.offerBypass)
        offerDontAsk = value(.offerDontAsk, d.offerDontAsk)
        rowDetail = value(.rowDetail, d.rowDetail)
        runningIndicator = value(.runningIndicator, d.runningIndicator)
        toolbarModelName = value(.toolbarModelName, d.toolbarModelName)
        newChatFolder = value(.newChatFolder, d.newChatFolder)
        toolCallVisibility = value(.toolCallVisibility, d.toolCallVisibility)
        doubleClickOpensWindow = value(.doubleClickOpensWindow, d.doubleClickOpensWindow)
        showTips = value(.showTips, d.showTips)
    }
}

extension EnvironmentValues {
    /// The app's appearance settings, set once at each window's root.
    @Entry public var appearance = Appearance()
}
