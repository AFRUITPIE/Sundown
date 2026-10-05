import SwiftUI
import SundownKit

/// Chat ▸ Previous Prompt and Next Prompt, for one window: the menu asks here, and the transcript,
/// which knows what's on screen, scrolls (`TranscriptView.goToPrompt`).
@MainActor
@Observable
public final class PromptNavigator {
    public private(set) var direction: PromptNavigation.Direction = .next
    /// Bumped by every request, so the transcript moves on each press.
    public private(set) var step = 0

    public func go(_ direction: PromptNavigation.Direction) {
        self.direction = direction
        step += 1
    }
}

extension EnvironmentValues {
    /// The window's Previous and Next Prompt, for its transcript.
    @Entry var promptNavigator: PromptNavigator?
}
