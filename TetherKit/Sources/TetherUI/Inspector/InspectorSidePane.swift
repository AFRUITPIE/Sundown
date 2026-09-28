import AppKit
import SwiftUI

/// The widths the window's columns add up to.
enum InspectorWidth {
    static let min: CGFloat = 220
    static let ideal: CGFloat = 280
    static let max: CGFloat = 420
    /// The sidebar's minimum: room for New Chat and the sidebar button beside the window's buttons.
    static let sidebar: CGFloat = 220
    /// The chat's: the detail column's, with the title and the model, effort and permissions menus
    /// in its toolbar clear of the `»` overflow.
    static let chat: CGFloat = 440
    /// The chat's beside the inspector column, whose width the detail column's toolbar also has.
    static let chatBesidePane: CGFloat = 340

    static func clamp(_ width: CGFloat) -> CGFloat { Swift.min(Swift.max(width, min), max) }
}

/// Settings ▸ Advanced ▸ Show Panes In ▸ Inspector: the panes in a column at the chat's trailing
/// edge, full height, under the toolbar as SwiftUI's inspector is. It's in the detail column rather
/// than SwiftUI's `.inspector`, whose split view, nested around the sidebar's, made the window's
/// minimum its current width while it was open (see AGENTS.md). Its leading edge drags its width,
/// which is kept when the drag ends.
struct InspectorSidePane: View {
    @Bindable var window: WindowModel
    /// The detail column's width, which a drag can't take the chat below its minimum of.
    let detailWidth: DetailWidth
    /// The width while its edge is being dragged, and where the drag started.
    @State private var drag: (start: CGFloat, width: CGFloat)?

    private var width: CGFloat { drag?.width ?? window.app.inspectorWidth }

    var body: some View {
        InspectorView(window: window, selectedTaskID: $window.inspectedTaskID)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }
            .overlay(alignment: .leading) {
                Divider().ignoresSafeArea()
            }
            .overlay(alignment: .leading) { resizeEdge }
    }

    /// A strip over the divider that drags the column's width, with the resize pointer.
    private var resizeEdge: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: -4)
            .ignoresSafeArea(edges: .bottom)
            .pointerStyle(.frameResize(position: .leading))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = drag?.start ?? window.app.inspectorWidth
                        let room = detailWidth.value - InspectorWidth.chatBesidePane
                        drag = (start, InspectorWidth.clamp(Swift.min(start - value.translation.width, room)))
                    }
                    .onEnded { _ in
                        if let drag { window.app.inspectorWidth = drag.width }
                        drag = nil
                    }
            )
            .accessibilityHidden(true)
    }
}

/// The detail column's width, measured as it changes and read only when the inspector's edge is
/// dragged. A box, so measuring it redraws nothing.
final class DetailWidth {
    var value: CGFloat = .infinity
}
