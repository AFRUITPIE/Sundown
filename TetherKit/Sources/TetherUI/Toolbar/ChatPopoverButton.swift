import SwiftUI
import TetherKit

/// A toolbar button that opens a popover about the chat on screen: Context, MCP, Plan Usage.
/// Disabled on New Chat, where there's no chat to say anything about.
struct ChatPopoverButton<Label: View, Content: View>: View {
    let title: String
    let window: WindowModel
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: (ThreadModel, HostConnection) -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            SwiftUI.Label { Text(title) } icon: { label() }
        }
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

extension ChatPopoverButton where Label == Image {
    init(title: String, systemImage: String, window: WindowModel,
         @ViewBuilder content: @escaping (ThreadModel, HostConnection) -> Content) {
        self.init(title: title, window: window, label: { Image(systemName: systemImage) }, content: content)
    }
}

/// How full the chat's context window is, as the Context button's icon: SF Symbols' gauge at the
/// nearest of its steps. A symbol, not a drawn gauge, so the button shares a glass capsule with the
/// buttons beside it. Asks the host after each turn ends, while the chat is loaded there.
struct ContextGauge: View {
    let window: WindowModel

    /// The gauge symbol for how full the window is: 0, 33, 50, 67 or 100 percent.
    static func symbol(_ fill: Double?) -> String {
        guard let fill else { return "gauge.with.dots.needle.0percent" }
        let step = [0, 33, 50, 67, 100].min { abs(Double($0) / 100 - fill) < abs(Double($1) / 100 - fill) }!
        return "gauge.with.dots.needle.\(step)percent"
    }

    var body: some View {
        let fill = window.selectedThread?.contextFill
        Image(systemName: Self.symbol(fill))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityValue(fill.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unknown")
            .task(id: Key(thread: window.selectedThread?.id, turn: window.selectedThread?.lastFinishedTurn)) {
                guard let thread = window.selectedThread, let connection = window.connection,
                      connection.isLoaded(thread),
                      let usage = try? await connection.contextUsage(thread),
                      let breakdown = ContextBreakdown(usage) else { return }
                thread.contextFill = breakdown.fill
            }
    }

    private struct Key: Equatable { let thread: String?; let turn: String? }
}

extension View {
    /// A popover's Form at a fixed width and as tall as its rows: a Form scrolls, so on its own it
    /// asks for no height at all.
    func popoverSize(width: CGFloat) -> some View {
        frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
/// The Context gauge's steps, at toolbar size.
#Preview("Context gauge") {
    HStack(spacing: 16) {
        ForEach([nil, 0.1, 0.4, 0.55, 0.7, 0.95] as [Double?], id: \.self) { fill in
            Image(systemName: ContextGauge.symbol(fill))
        }
    }
    .padding()
}
#endif
