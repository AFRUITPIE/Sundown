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

/// How full the chat's context window is, as the Context button's icon: SF Symbols' open gauge drawn
/// to how full it is (a variable value), green, then yellow from 70%, red from 90%. A symbol, not a
/// drawn gauge, so the button shares a glass capsule with the buttons beside it. Asks the host after
/// each turn ends, while the chat is loaded there.
struct ContextGauge: View {
    let window: WindowModel

    /// Green to 70%, yellow to 90%, red beyond; nothing until the fill is known.
    static func color(_ fill: Double?) -> Color? {
        guard let fill else { return nil }
        return fill < 0.7 ? .green : fill < 0.9 ? .yellow : .red
    }

    var body: some View {
        let fill = window.selectedThread?.contextFill
        Image(systemName: "gauge.open", variableValue: fill ?? 0)
            // Drawn as far round as the value, not dimmed in layers.
            .symbolVariableValueMode(.draw)
            // Shaded as the SF Symbols app's Gradients option shades it.
            .symbolColorRenderingMode(.gradient)
            .foregroundStyle(Self.color(fill).map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
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
/// The Context gauge unknown, then filling through green, yellow and red, at toolbar size.
#Preview("Context gauge") {
    HStack(spacing: 16) {
        ForEach([nil, 0.2, 0.55, 0.75, 0.88, 0.95] as [Double?], id: \.self) { fill in
            Image(systemName: "gauge.open", variableValue: fill ?? 0)
                .symbolVariableValueMode(.draw)
                .symbolColorRenderingMode(.gradient)
                .foregroundStyle(ContextGauge.color(fill).map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
        }
    }
    .font(.title2)
    .padding()
}
#endif

