#if DEBUG
import Foundation
import Observation
import Testing
import TetherProtocol
@testable import TetherKit
@testable import TetherUI

/// The Chats layout doesn't show what a chat is doing, so a chat starting a turn, finishing one or
/// asking for something doesn't regroup it; Activity's Needs You does.
@MainActor
@Suite
struct SidebarListTests {
    /// A chat that isn't waiting on anything, in the sample's sidebar.
    private func window(_ style: Appearance.SidebarStyle) -> (WindowModel, ThreadModel) {
        let app = AppModel.sample()
        app.appearance.sidebar = style
        let w = WindowModel.sample(app)
        let idle = w.sidebarThreads.first { $0.pending.isEmpty && $0.status != .requiresAction }!
        return (w, idle)
    }

    private func needsYou(_ w: WindowModel) -> [String] {
        w.sidebarList(w.sidebarThreads).first { $0.id == SidebarSection.needsYouID }?.chats.map(\.id) ?? []
    }

    @Test func theChatsLayoutDoesntFollowWhatAChatIsDoing() {
        let (w, chat) = window(.chats)
        let regrouped = Changed()
        withObservationTracking { _ = w.sidebarList(w.sidebarThreads) } onChange: { regrouped.happened = true }

        chat.apply(.threadStatusChanged(.init(threadId: chat.id, seq: 1, status: .requiresAction)))
        chat.addPending(.samplePermission())

        #expect(!regrouped.happened)
        #expect(needsYou(w).isEmpty)
    }

    @Test func activityListsWhatNeedsYouOnTop() {
        let (w, chat) = window(.activity)
        let regrouped = Changed()
        withObservationTracking { _ = w.sidebarList(w.sidebarThreads) } onChange: { regrouped.happened = true }

        #expect(!needsYou(w).contains(chat.id))
        chat.apply(.threadStatusChanged(.init(threadId: chat.id, seq: 1, status: .requiresAction)))

        #expect(regrouped.happened)
        #expect(needsYou(w).contains(chat.id))
    }
}

/// Observation's `onChange` is `@Sendable`, so the flag it sets needs a reference to live in.
private final class Changed: @unchecked Sendable {
    var happened = false
}
#endif
