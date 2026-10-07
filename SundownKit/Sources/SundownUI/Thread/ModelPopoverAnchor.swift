import SwiftUI
import SundownKit

/// The window a composer belongs to, for Chat ▸ Model and Effort…: held weakly, equal when it's the
/// same window, as `InspectSubagentAction` holds it, so the shell's updates don't redraw the field.
struct ComposerWindow: Equatable {
    weak var window: WindowModel?
    static func == (a: Self, b: Self) -> Bool { a.window === b.window }
}

extension EnvironmentValues {
    @Entry var composerWindow = ComposerWindow()
}

/// Chat ▸ Model and Effort… (⌃⌘M) opens the toolbar's model popover from the message field, its arrow
/// pointing down at the field: the field is in every chat and in New Chat, where the toolbar's button
/// may be in » or customized away. Reads the window's request here, so only this redraws.
struct ModelPopoverAnchor: ViewModifier {
    @Environment(\.composerWindow) private var composer
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                if let window = composer.window {
                    ModelEffortForm(settings: .current(window))
                        .popoverSize(width: 300)
                }
            }
            .onChange(of: composer.window?.modelPopoverRequested ?? false, initial: true) { _, requested in
                guard requested, let window = composer.window else { return }
                window.modelPopoverRequested = false
                isPresented = true
            }
    }
}
