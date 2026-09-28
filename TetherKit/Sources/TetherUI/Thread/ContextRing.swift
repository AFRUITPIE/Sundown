import AppKit
import SwiftUI
import TetherKit
import TetherProtocol

/// How full the chat's context window is, as a small ring beside Send, the way the desktop app
/// keeps it beside its model picker. Asked for once per turn, not per delta; clicking it opens the
/// Session pane with the breakdown.
struct ContextRing: View {
    let thread: ThreadModel
    let connection: HostConnection
    @State private var used: (tokens: Double, limit: Double)?
    @Environment(\.showInspectorPane) private var showPane

    /// `used` only for a preview, which has no daemon to ask.
    init(thread: ThreadModel, connection: HostConnection, used: (tokens: Double, limit: Double)? = nil) {
        self.thread = thread
        self.connection = connection
        _used = State(initialValue: used)
    }

    private var fraction: Double {
        guard let used, used.limit > 0 else { return 0 }
        return min(used.tokens / used.limit, 1)
    }

    /// Quiet until it's worth noticing.
    private var tint: Color { fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .secondary }

    var body: some View {
        Group {
            if let used, used.limit > 0 {
                Button { showPane(.session) } label: {
                    // A gauge, which VoiceOver reads as Context and how full, drawn as a thin ring:
                    // the system's circular styles are a widget's size, or a pie that drops the tint.
                    Gauge(value: fraction) { Text("Context") }
                        .gaugeStyle(RingGaugeStyle(tint: tint))
                        // Wider to click, never taller than Send beside it.
                        .padding(.horizontal, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Level with Send, which sits on the text's baseline: a symbol's center is half a
                // cap height above the baseline, and so is the ring's.
                .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + Self.symbolCenterHeight }
                .help("Context: \(Format.tokens(used.tokens)) of \(Format.tokens(used.limit)) tokens (\(Int(fraction * 100))%)")
            }
        }
        // Once per finished turn: the context only settles when a turn ends.
        .task(id: Key(thread: thread.id, turn: thread.lastFinishedTurn, loaded: connection.isLoaded(thread))) {
            guard connection.isLoaded(thread), let u = try? await connection.contextUsage(thread) else { return }
            let tokens = u["totalTokens"]?.doubleValue ?? 0
            let limit = u["maxTokens"]?.doubleValue ?? u["rawMaxTokens"]?.doubleValue ?? 0
            used = (tokens, limit)
        }
    }

    private struct Key: Equatable { let thread: String; let turn: String?; let loaded: Bool }

    /// How far above the baseline Send's symbol is centered: half the body font's cap height.
    private static let symbolCenterHeight = NSFont.preferredFont(forTextStyle: .body).capHeight / 2
}

/// A gauge as a thin ring, filled clockwise from the top, the size of a small symbol.
struct RingGaugeStyle: GaugeStyle {
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var size = 16

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: configuration.value)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Opens the window's inspector on a pane, from views that don't hold the window. Compared by
/// owner, like `InspectSubagentAction`.
struct ShowInspectorPaneAction: Equatable {
    private let owner: ObjectIdentifier?
    private let show: @MainActor (InspectorPane) -> Void

    init(owner: AnyObject?, show: @escaping @MainActor (InspectorPane) -> Void) {
        self.owner = owner.map(ObjectIdentifier.init)
        self.show = show
    }

    @MainActor func callAsFunction(_ pane: InspectorPane) { show(pane) }

    static func == (a: Self, b: Self) -> Bool { a.owner == b.owner }
}

#if DEBUG
#Preview("Composer with the context ring") {
    let connection = HostConnection.sample()
    let thread = ThreadModel.sampleIdleChat()
    VStack(spacing: 20) {
        ForEach([0.3, 0.8, 0.95], id: \.self) { fill in
            Composer(connection: connection, cwd: thread.cwd, thread: thread,
                     accessory: AnyView(ContextRing(thread: thread, connection: connection, used: (fill * 200_000, 200_000))),
                     submit: { _ in })
        }
    }
    .padding(20)
    .frame(width: 560)
}
#endif

extension EnvironmentValues {
    @Entry var showInspectorPane = ShowInspectorPaneAction(owner: nil) { _ in }
}
