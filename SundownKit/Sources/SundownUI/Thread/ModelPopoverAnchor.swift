import SwiftUI
import SundownKit

/// Chat ▸ Model and Effort… (⌃⌘M) opens the toolbar's model popover from the message field, its arrow
/// pointing down at the field: the field is in every chat and in New Chat, where the toolbar's button
/// may be in » or customized away. Reads the window's request here, so only this redraws.
struct ModelPopoverAnchor: ViewModifier {
    @Environment(\.windowRef) private var windowRef
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                if let window = windowRef.window {
                    ModelEffortForm(settings: .current(window))
                        .popoverSize(width: 300)
                }
            }
            .onChange(of: windowRef.window?.modelPopoverRequested ?? false, initial: true) { _, requested in
                guard requested, let window = windowRef.window else { return }
                window.modelPopoverRequested = false
                isPresented = true
            }
    }
}
