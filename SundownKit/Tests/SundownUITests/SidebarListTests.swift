#if DEBUG
import Foundation
@testable import SundownFixtures
import SundownTestSupport
import Testing
import TetherProtocol
@testable import SundownKit
@testable import SundownUI

/// The sidebar doesn't show what a chat is doing, so a chat starting a turn, finishing one or
/// asking for something doesn't regroup it.
@MainActor
@Suite
struct SidebarListTests {
    @Test func theListDoesntFollowWhatAChatIsDoing() {
        let w = WindowModel.sample(.sample())
        let chat = w.sidebarThreads.first { $0.pending.isEmpty && $0.status != .requiresAction }!
        expectUnchanged(reading: { _ = w.sidebarList(w.sidebarThreads) }) {
            chat.apply(.threadStatusChanged(.init(threadId: chat.id, seq: 1, status: .requiresAction)))
            chat.addPending(.samplePermission())
        }
    }
}
#endif
