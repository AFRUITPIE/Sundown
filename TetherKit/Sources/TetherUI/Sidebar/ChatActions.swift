import AppKit
import SwiftUI
import TetherKit

/// What can be done to a chat as a whole, in one place for the Chat menu and a sidebar row's
/// context menu. The menu bar lists every item and disables what doesn't apply; a context menu
/// shows only what does.
struct ChatActionItems: View {
    let window: WindowModel
    let thread: ThreadModel?
    /// The context menu hides unavailable items; the menu bar dims them.
    var hidesUnavailable = false
    @Environment(\.openWindow) private var openWindow

    private var connection: HostConnection? { window.connection }
    private var folder: String? { connection?.host.isLocal == true ? thread?.cwd : nil }

    var body: some View {
        item("Open in New Window", enabled: thread != nil) {
            if let thread { openWindow(value: WindowTarget(hostID: window.hostID, threadID: thread.id)) }
        }
        Divider()
        item("Rename…", enabled: thread != nil) { window.rename(thread) }
        item("Duplicate", enabled: thread != nil && connection != nil) {
            guard let thread, let connection else { return }
            Task { if let fork = await connection.fork(thread) { window.open(threadID: fork.id) } }
        }
        item("Show in Finder", enabled: folder != nil) {
            if let folder { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
        }
        Divider()
        item("Delete…", enabled: thread != nil) { window.deleting = thread }
    }

    @ViewBuilder private func item(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled || !hidesUnavailable {
            Button(title, action: action).disabled(!enabled)
        }
    }
}

/// Rename and Delete's alerts, for whichever chat the window's `renaming` or `deleting` names.
/// On the window rather than the sidebar, so the Chat menu can ask for them with the sidebar hidden.
struct ChatActionAlerts: ViewModifier {
    @Bindable var window: WindowModel

    func body(content: Content) -> some View {
        content
            .alert("Rename Chat", isPresented: Binding(get: { window.renaming != nil }, set: { if !$0 { window.rename(nil) } })) {
                TextField("Title", text: $window.renameTitle)
                Button("Rename") {
                    let title = window.renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let thread = window.renaming, let connection = window.connection, !title.isEmpty {
                        Task { await connection.rename(thread, title) }
                    }
                    window.rename(nil)
                }
                Button("Cancel", role: .cancel) { window.rename(nil) }
            }
            // Deleting a chat removes its transcript from the host for good, so it's confirmed. The
            // button isn't styled destructive: deleting is what the person just chose.
            .alert(deleteTitle, isPresented: presented(\.deleting)) {
                Button("Delete") { delete() }
                Button("Cancel", role: .cancel) { window.deleting = nil }
            } message: {
                Text("Its transcript is removed from \(window.host?.name ?? "the host"). This can’t be undone.")
            }
    }

    private var deleteTitle: String {
        "Delete “\(window.deleting?.title ?? "Chat")”?"
    }

    private func presented(_ key: ReferenceWritableKeyPath<WindowModel, ThreadModel?>) -> Binding<Bool> {
        Binding(get: { window[keyPath: key] != nil }, set: { if !$0 { window[keyPath: key] = nil } })
    }


    private func delete() {
        guard let thread = window.deleting, let connection = window.connection else { return }
        window.deleting = nil
        // Every window showing it moves to New Chat first, so none is left on a deleted chat.
        for other in window.app.openWindows where other.selectedThread === thread { other.newChat() }
        Task { await connection.delete(thread) }
    }
}

extension View {
    func chatActionAlerts(_ window: WindowModel) -> some View {
        modifier(ChatActionAlerts(window: window))
    }
}
