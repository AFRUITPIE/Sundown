#if DEBUG
import Foundation
import Observation
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
        let regrouped = Changed()
        withObservationTracking { _ = w.sidebarList(w.sidebarThreads) } onChange: { regrouped.happened = true }

        chat.apply(.threadStatusChanged(.init(threadId: chat.id, seq: 1, status: .requiresAction)))
        chat.addPending(.samplePermission())

        #expect(!regrouped.happened)
    }
}

/// Observation's `onChange` is `@Sendable`, so the flag it sets needs a reference to live in.
private final class Changed: @unchecked Sendable {
    var happened = false
}
#endif
