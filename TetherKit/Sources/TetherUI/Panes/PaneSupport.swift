import SwiftUI
import TetherKit

extension EnvironmentValues {
    /// Changes for a preview, which has no repository to read.
    @Entry var previewChanges: WorkingChanges?
}

extension View {
    /// What every pane's Form is dressed in, applied by the pane itself — and so by its previews too.
    func paneStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .lineLimit(1)
    }
}

/// A pane with nothing in it yet — says which, rather than showing a blank area.
/// Title only: what it would explain, the title already said.
struct PaneEmptyState: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
/// A pane as a tab shows it, filling a window-sized area.
@MainActor
func panePreview<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .frame(width: 760, height: 560)
}
#endif
