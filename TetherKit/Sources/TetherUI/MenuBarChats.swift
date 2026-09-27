import AppKit
import SwiftUI
import TetherKit

/// The menu bar extra's menu (Settings ▸ Notifications ▸ Show Chats in the Menu Bar): the chats
/// waiting on you, then those Claude is working in, each opening its chat, then New Chat.
public struct MenuBarChats: View {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    private var chats: [(HostConnection, ThreadModel)] {
        app.connections.values.flatMap { c in c.chats.map { (c, $0) } }
    }

    public var body: some View {
        let waiting = chats.filter { !$0.1.pending.isEmpty || $0.1.status == .requiresAction }
        let working = chats.filter { $0.1.isRunning && $0.1.pending.isEmpty && $0.1.status != .requiresAction }
        if waiting.isEmpty && working.isEmpty {
            Text("No Chats Running")
        }
        section("Waiting on You", waiting)
        section("Working", working)
        Divider()
        Button("New Chat") { app.showNewChat() }
        Button("Open Tether") { NSApp.activate() }
    }

    @ViewBuilder private func section(_ title: String, _ chats: [(HostConnection, ThreadModel)]) -> some View {
        if !chats.isEmpty {
            Section(title) {
                ForEach(chats.prefix(10), id: \.1.id) { connection, thread in
                    Button(thread.title) { app.showChat(host: connection.id, threadID: thread.id) }
                }
            }
        }
    }
}

/// The menu bar extra's icon: filled while a chat is waiting on you.
public struct MenuBarLabel: View {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        let waiting = app.connections.values.contains { $0.chats.contains { !$0.pending.isEmpty || $0.status == .requiresAction } }
        Label("Tether", systemImage: waiting ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
    }
}
