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
            // Animated, so the row is seen to move to Pinned and back.
            if let thread { withAnimation { window.togglePin(thread) } }
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        // In place on the row from its context menu, as Finder renames; in an alert from the Chat
        // menu, which may be used with the sidebar hidden.
        if hidesUnavailable, let thread {
            RenameButton()
                .renameAction { window.renamingInPlace = thread }
        } else {
            item("Rename…", enabled: thread != nil) { window.rename(thread) }
        }
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
            .alert("Rename Chat", isPresented: presented(\.renaming), presenting: window.renaming) { thread in
                TextField("Title", text: $window.renameTitle)
                Button("Rename") {
                    window.rename(thread, to: window.renameTitle)
                    window.rename(nil)
                }
                Button("Cancel", role: .cancel) { window.rename(nil) }
            }
            // Each dialog on a view of its own, so its severity or suppression toggle reaches it and
            // not the window's other dialogs, which the environment would pass them on to.
            .background {
                // Deleting a chat removes its transcript from the host for good.
                Color.clear
                    .confirmationDialog("Delete “\(window.deleting?.title ?? "Chat")”?", isPresented: presented(\.deleting),
                                        titleVisibility: .visible, presenting: window.deleting) { thread in
                        Button("Delete", role: .destructive) { delete(thread) }
                    } message: { _ in
                        Text("Its transcript is removed from \(window.host?.name ?? "the host"). This can’t be undone.")
                    }
                    .dialogSeverity(.critical)
            }
            .background {
                // The first offer, which Don't Ask Again turns off.
                Color.clear
                    .confirmationDialog("Remove Its Worktree?", isPresented: worktreePresented(losesWork: false),
                                        titleVisibility: .visible, presenting: window.worktreeToRemove) { target in
                        Button("Remove Worktree") { removeWorktree(target) }
                        Button("Keep", role: .cancel) { window.worktreeToRemove = nil }
                    } message: { target in
                        Text("The chat worked in \(name(target)), a worktree of its own. Removing it deletes the directory and its branch.")
                    }
                    .dialogSuppressionToggle(isSuppressed: Binding(get: { !window.app.appearance.offersWorktreeRemoval },
                                                                   set: { window.app.appearance.offersWorktreeRemoval = !$0 }))
            }
            .background {
                // Asked again, plainly, when removing it would lose work.
                Color.clear
                    .confirmationDialog(losingTitle, isPresented: worktreePresented(losesWork: true),
                                        titleVisibility: .visible, presenting: window.worktreeToRemove) { target in
                        Button("Remove Anyway", role: .destructive) { removeWorktree(target) }
                        Button("Keep", role: .cancel) { window.worktreeToRemove = nil }
                    } message: { target in
                        Text(target.discardCommits
                             ? "Removing \(name(target)) deletes its branch and the commits on it that aren’t merged anywhere else."
                             : "Removing \(name(target)) discards the changes in it that weren’t committed.")
                    }
                    .dialogSeverity(.critical)
            }
            .alert("Couldn’t Remove the Worktree", isPresented: presented(\.worktreeError), presenting: window.worktreeError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
            .sheet(item: $window.sideQuestion) { thread in
                if let connection = window.connection {
                    SideQuestionSheet(thread: thread, connection: connection)
                }
            }
            .alert(restoreTitle, isPresented: presented(\.restoring), presenting: window.restoring) { _ in
                restoreActions()
            } message: { _ in
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

    private func removeWorktree(_ target: WindowModel.WorktreeRemoval) {
        guard let connection = window.connection else { return }
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

    private func name(_ target: WindowModel.WorktreeRemoval) -> String { (target.path as NSString).lastPathComponent }

    private var losingTitle: String {
        window.worktreeToRemove?.discardCommits == true ? "Its Branch Has Commits Nowhere Else" : "The Worktree Has Uncommitted Changes"
    }

    /// The first offer, or a second ask that would lose work.
    private func worktreePresented(losesWork: Bool) -> Binding<Bool> {
        Binding(get: { window.worktreeToRemove.map { $0.losesWork == losesWork } ?? false },
                set: { if !$0 { window.worktreeToRemove = nil } })
    }

    /// Shown while `key` holds something; dismissing clears it.
    private func presented<Value>(_ key: ReferenceWritableKeyPath<WindowModel, Value?>) -> Binding<Bool> {
        Binding(get: { window[keyPath: key] != nil }, set: { if !$0 { window[keyPath: key] = nil } })
    }

    private func delete(_ thread: ThreadModel) {
        guard let connection = window.connection else { return }
        window.deleting = nil
        // Every window showing it moves to New Chat first, so none is left on a deleted chat.
        for other in window.app.openWindows where other.selectedThread === thread { other.newChat() }
        window.app.setPinned(false, thread.id, on: window.hostID)
        window.app.forgetDraft(for: thread.id)
        Task { await connection.delete(thread) }
        window.offerWorktreeRemoval(for: thread)
    }
}

extension View {
    func chatActionAlerts(_ window: WindowModel) -> some View {
        modifier(ChatActionAlerts(window: window))
    }
}

#if DEBUG
/// The Chat menu's actions for a chat, as buttons: a preview can't open a menu.
#Preview("Chat actions") {
    let window = WindowModel.sample()
    VStack(alignment: .leading) {
        ChatActionItems(window: window, thread: window.connection?.chats.first)
    }
    .buttonStyle(.borderless)
    .padding()
}
#endif
