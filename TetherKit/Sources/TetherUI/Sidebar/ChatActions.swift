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
        // Pinned in this app, per host; ⌥⌘P from the menu bar.
        item(thread.map { window.isPinned($0) } == true ? "Unpin" : "Pin", enabled: thread != nil) {
            if let thread { window.togglePin(thread) }
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        item("Rename…", enabled: thread != nil) { window.rename(thread) }
        item("Duplicate", enabled: thread != nil && connection != nil) {
            guard let thread, let connection else { return }
            Task { if let fork = await connection.fork(thread) { window.open(threadID: fork.id) } }
        }
        item("Show in Finder", enabled: folder != nil) {
            if let folder { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
        }
        // Out of the list without deleting anything; View ▸ Show ▸ Archived brings it back.
        item(thread?.isArchived == true ? "Unarchive" : "Archive", enabled: thread != nil && connection != nil) {
            if let thread { window.setArchived([thread], !thread.isArchived) }
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
            .alert(worktreeTitle,
                   isPresented: Binding(get: { window.worktreeToRemove != nil }, set: { if !$0 { window.worktreeToRemove = nil } })) {
                Button(worktreeAction, role: window.worktreeToRemove.map { $0.force || $0.discardCommits } == true ? .destructive : nil) {
                    removeWorktree()
                }
                Button("Keep", role: .cancel) { window.worktreeToRemove = nil }
            } message: {
                Text(worktreeMessage)
            }
            .alert("Couldn’t Remove the Worktree",
                   isPresented: Binding(get: { window.worktreeError != nil }, set: { if !$0 { window.worktreeError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(window.worktreeError ?? "")
            }
            .sheet(isPresented: $window.askingSideQuestion) {
                if let thread = window.selectedThread, let connection = window.connection {
                    SideQuestionSheet(thread: thread, connection: connection)
                }
            }
            .alert(restoreTitle, isPresented: Binding(get: { window.restoring != nil }, set: { if !$0 { window.restoring = nil } })) {
                restoreActions()
            } message: {
                Text(restoreMessage)
            }
    }

    @ViewBuilder private func restoreActions() -> some View {
        if case .success(let preview) = window.restoring?.result, preview.canRewind, !preview.files.isEmpty {
            Button("Restore") {
                guard let restore = window.restoring, let connection = window.connection else { return }
                window.restoring = nil
                Task {
                    do {
                        let done = try await connection.rewindFiles(restore.thread, to: restore.messageID, dryRun: false)
                        // Said so only when it didn't work; the files changing is the confirmation.
                        if !done.canRewind {
                            window.restoring = .init(thread: restore.thread, messageID: restore.messageID, result: .success(done))
                        }
                    } catch {
                        window.restoring = .init(thread: restore.thread, messageID: restore.messageID, result: .failure(error))
                    }
                }
            }
            Button("Cancel", role: .cancel) { window.restoring = nil }
        } else {
            Button("OK", role: .cancel) { window.restoring = nil }
        }
    }

    private var restoreTitle: String {
        switch window.restoring?.result {
        case .success(let p) where p.canRewind && !p.files.isEmpty: "Restore Files to Before This Message?"
        case .success(let p) where p.canRewind: "No Files to Restore"
        default: "Can’t Restore Files"
        }
    }

    private var restoreMessage: String {
        switch window.restoring?.result {
        case .success(let p) where p.canRewind && !p.files.isEmpty:
            let names = p.files.prefix(5).map { ($0 as NSString).lastPathComponent }
            let more = p.files.count > 5 ? " and \(p.files.count - 5) more" : ""
            return "\(names.joined(separator: ", "))\(more) will go back to how they were before this message (\(p.insertions) lines added and \(p.deletions) removed since). The conversation stays as it is."
        case .success(let p) where p.canRewind:
            return "Claude hasn’t changed any files since this message."
        case .success(let p):
            return p.error ?? "Claude Code has no checkpoint for this message."
        case .failure(let e):
            return e.localizedDescription
        case nil:
            return ""
        }
    }

    private func removeWorktree() {
        guard let target = window.worktreeToRemove, let connection = window.connection else { return }
        window.worktreeToRemove = nil
        Task {
            do {
                try await connection.removeWorktree(target.path, force: target.force, discardCommits: target.discardCommits)
            } catch let error as RPCError where error.code == RPCError.worktreeDirty && !target.force {
                // Uncommitted changes, or commits merged nowhere else: asked again, plainly, before
                // they're lost. The second ask keeps what the first answered.
                var next = target
                next.force = true
                window.worktreeToRemove = next
            } catch let error as RPCError where error.code == RPCError.worktreeUnmerged && !target.discardCommits {
                var next = target
                next.discardCommits = true
                window.worktreeToRemove = next
            } catch {
                window.worktreeError = error.localizedDescription
            }
        }
    }

    private var worktreeName: String { ((window.worktreeToRemove?.path ?? "") as NSString).lastPathComponent }

    private var worktreeTitle: String {
        guard let target = window.worktreeToRemove else { return "Remove Its Worktree?" }
        if target.discardCommits { return "Its Branch Has Commits Nowhere Else" }
        if target.force { return "The Worktree Has Uncommitted Changes" }
        return "Remove Its Worktree?"
    }

    private var worktreeAction: String {
        guard let target = window.worktreeToRemove else { return "Remove Worktree" }
        return target.force || target.discardCommits ? "Remove Anyway" : "Remove Worktree"
    }

    private var worktreeMessage: String {
        guard let target = window.worktreeToRemove else { return "" }
        if target.discardCommits { return "Removing \(worktreeName) deletes its branch and the commits on it that aren’t merged anywhere else." }
        if target.force { return "Removing \(worktreeName) discards the changes in it that weren’t committed." }
        return "The chat worked in \(worktreeName), a worktree of its own. Removing it deletes the folder and its branch."
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
        window.app.setPinned(false, thread.id, on: window.hostID)
        Task { await connection.delete(thread) }
        window.offerWorktreeRemoval(for: thread)
    }
}

extension View {
    func chatActionAlerts(_ window: WindowModel) -> some View {
        modifier(ChatActionAlerts(window: window))
    }
}
