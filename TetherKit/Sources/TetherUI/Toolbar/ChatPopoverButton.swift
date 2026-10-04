import SwiftUI
import TetherKit

/// A toolbar button that opens a popover about the chat on screen: Context, MCP, Plan Usage.
/// Disabled on New Chat, where there's no chat to say anything about.
struct ChatPopoverButton<Content: View>: View {
    let title: String
    let systemImage: String
    let window: WindowModel
    @ViewBuilder let content: (ThreadModel, HostConnection) -> Content
    @State private var isPresented = false

    var body: some View {
        Button(title, systemImage: systemImage) { isPresented.toggle() }
            .help(title)
            .disabled(window.selectedThread == nil || window.connection == nil)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                // A stack, so the popover always has one view, whether or not there's a chat.
                VStack {
                    if let thread = window.selectedThread, let connection = window.connection {
                        content(thread, connection)
                    }
                }
            }
    }
}

extension View {
    /// A popover's Form at a fixed width and as tall as its rows: a Form scrolls, so on its own it
    /// asks for no height at all.
    func popoverSize(width: CGFloat) -> some View {
        frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}
