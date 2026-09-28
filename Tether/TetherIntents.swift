import AppIntents
import TetherKit
import TetherUI

/// Shortcuts: start a chat in a folder with a prompt, ready to send or sent.
struct StartChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Chat"
    static let description = IntentDescription("Opens a new chat on this Mac in Tether, in a directory, with a prompt in the message field or sent.")

    @Parameter(title: "Directory", description: "The directory Claude works in, such as ~/Code/my-app.")
    var folder: String?

    @Parameter(title: "Prompt")
    var prompt: String?

    @Parameter(title: "Send Right Away", default: false)
    var send: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Start a chat in \(\.$folder) with \(\.$prompt)") {
            \.$send
        }
    }

    /// Opens a `tether://` link, which SwiftUI routes to a window of the app; one that sends
    /// carries a token only this process knows.
    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        let link = TetherLink.newChat(host: HostConfig.local.id, folder: folder, prompt: prompt,
                                      sendToken: send ? TetherLink.authorizeSend() : nil)
        return .result(opensIntent: OpenURLIntent(link.url))
    }
}

struct TetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartChatIntent(),
                    phrases: ["Start a chat in \(.applicationName)", "Ask Claude in \(.applicationName)"],
                    shortTitle: "Start a Chat",
                    systemImageName: "bubble.left.and.text.bubble.right")
    }
}
