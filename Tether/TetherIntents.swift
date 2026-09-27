import AppIntents
import TetherUI

/// Shortcuts: start a chat in a folder with a prompt, ready to send or sent.
struct StartChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Chat"
    static let description = IntentDescription("Opens a new chat on this Mac in Tether, in a folder, with a prompt in the message field or sent.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder", description: "The folder Claude works in, such as ~/Code/my-app.")
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

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.current?.startChat(folder: folder, prompt: prompt, send: send)
        return .result()
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
