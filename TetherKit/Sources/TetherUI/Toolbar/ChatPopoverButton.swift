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

/// How full the chat's context window is, as the Context button's icon: SwiftUI's `Gauge`, a ring
/// that fills. Asks the host after each turn ends, while the chat is loaded there; empty until then.
struct ContextGauge: View {
    let window: WindowModel

    var body: some View {
        let fill = window.selectedThread?.contextFill
        Gauge(value: fill ?? 0) { Text("Context") }
            .gaugeStyle(.toolbarRing)
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

/// A gauge as a ring the size of a toolbar symbol: the accessory styles are widget-sized.
struct ToolbarRingGaugeStyle: GaugeStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().stroke(.tertiary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: configuration.value)
                .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .padding(1)
    }
}

extension GaugeStyle where Self == ToolbarRingGaugeStyle {
    static var toolbarRing: ToolbarRingGaugeStyle { .init() }
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
/// The Context gauge empty, a third full, and nearly full, at toolbar size.
#Preview("Context gauge") {
    HStack(spacing: 16) {
        ForEach([0, 0.33, 0.9], id: \.self) { value in
            Gauge(value: value) { Text("Context") }
                .gaugeStyle(.toolbarRing)
        }
    }
    .padding()
}
#endif
