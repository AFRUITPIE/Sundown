import SwiftUI
import SundownKit
import TetherProtocol

/// How full the chat's context window is, by category: the toolbar's Context popover. Owns the
/// context-usage fetch, so the daemon is asked only while the popover is open.
struct ContextView: View {
    let thread: ThreadModel
    let connection: HostConnection
    @State private var usage: Loaded<JSONValue?>
    /// False when a preview seeded a result: there is nothing to ask, and asking would replace it.
    private let fetchesUsage: Bool

    init(thread: ThreadModel, connection: HostConnection, usage: Loaded<JSONValue?>? = nil) {
        self.thread = thread
        self.connection = connection
        self._usage = State(initialValue: usage ?? .loading)
        self.fetchesUsage = usage == nil
    }

    var body: some View {
        Form {
            Section("Context") {
                switch usage {
                case .loading:
                    // Transient: every other branch replaces it.
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                case .ready(let u):
                    contextBody(u)
                }
            }
        }
        .paneStyle()
        // Keyed on the thread too, or two chats share a stale result; and on the last finished
        // turn, since the context only settles when a turn ends.
        .task(id: Key(threadId: thread.id, turn: thread.lastFinishedTurn)) {
            guard fetchesUsage else { return }
            await refresh()
        }
    }

    private struct Key: Equatable { let threadId: String; let turn: String? }

    @ViewBuilder private func contextBody(_ u: JSONValue?) -> some View {
        if let u, let breakdown = ContextBreakdown(u) {
            LabeledContent("Used", value: "\(Format.tokens(breakdown.total)) of \(Format.tokens(breakdown.limit))")
            ContextBar(breakdown: breakdown)
            ForEach(breakdown.categories) { ContextCategoryRow(category: $0) }
        } else {
            Text("No Data").foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        // The daemon only answers for a loaded thread; sending a message loads it.
        guard connection.isLoaded(thread) else {
            usage = .failed("Send a message to load context usage.")
            return
        }
        usage = .loading
        do {
            let u = try await connection.contextUsage(thread)
            usage = .ready(u)
            if let breakdown = u.flatMap(ContextBreakdown.init) { thread.contextFill = breakdown.fill }
        } catch is CancellationError {
            // Superseded by a newer refresh; that one owns the state from here.
        } catch {
            usage = .failed(error.localizedDescription)
        }
    }
}

/// The plan's usage limit: the toolbar's optional Plan Usage popover.
struct PlanUsageView: View {
    let thread: ThreadModel

    var body: some View {
        Form {
            Section("Plan Usage") {
                if let limit = thread.rateLimit, let used = limit.utilization {
                    let percent = Int((used * 100).rounded())
                    LabeledContent(limit.name.capitalized, value: "\(percent)%")
                        .accessibilityHidden(true)
                    Gauge(value: min(used, 1)) {
                        Text(limit.name.capitalized)
                    }
                    // A thin bar that fills, as Context's is: the default style's marker reads
                    // as a slider's thumb.
                    .gaugeStyle(.accessoryLinearCapacity)
                    .labelsHidden()
                    // The accent color until the limit is near, and said in words as well.
                    .tint(limit.status == .allowed ? nil : limit.status == .warning ? .orange : .red)
                    .accessibilityValue("\(percent) percent\(limit.status == .allowed ? "" : limit.status == .warning ? ", near the limit" : ", limit reached")")
                    if let reset = limit.resetsAt {
                        LabeledContent("Resets", value: reset.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    Text("No Data").foregroundStyle(.secondary)
                }
            }
        }
        .paneStyle()
    }
}

/// A fetched value. Every case renders, so no spinner is left with nothing behind it.
enum Loaded<Value> {
    case loading
    case ready(Value)
    case failed(String)

    var isLoading: Bool { if case .loading = self { return true }; return false }
}

#if DEBUG
/// What `thread/contextUsage` hands back for a chat that has been running a while.
private let sampleContextUsage: JSONValue = [
    "totalTokens": 84_300,
    "maxTokens": 200_000,
    "categories": [
        ["name": "System prompt", "tokens": 3_100, "kind": "used"],
        ["name": "System tools", "tokens": 12_600, "kind": "used"],
        ["name": "MCP tools", "tokens": 4_200, "kind": "used"],
        ["name": "Memory files", "tokens": 2_000, "kind": "used"],
        ["name": "Skills", "tokens": 1_000, "kind": "used"],
        ["name": "Messages", "tokens": 61_400, "kind": "used"],
        ["name": "Free space", "tokens": 82_700, "kind": "free"],
        ["name": "Autocompact buffer", "tokens": 33_000, "kind": "buffer"],
        ["name": "MCP tools (deferred)", "tokens": 9_800, "kind": "deferred"],
    ],
]

#Preview("Context (loaded)") {
    ContextView(thread: .sampleIdleChat(), connection: .sample(), usage: .ready(sampleContextUsage))
        .frame(width: 340, height: 420)
}

#Preview("Context (no data)") {
    ContextView(thread: .sampleIdleChat(), connection: .sample(), usage: .ready(nil))
        .frame(width: 340, height: 160)
}

#Preview("Context (loading)") {
    ContextView(thread: .sampleIdleChat(), connection: .sample(), usage: .loading)
        .frame(width: 340, height: 160)
}

#Preview("Context (failed)") {
    ContextView(thread: .sampleIdleChat(), connection: .sample(), usage: .failed("The chat is no longer running on this host."))
        .frame(width: 340, height: 160)
}

#Preview("Plan Usage") {
    PlanUsageView(thread: .sampleRateLimited("allowed_warning", kind: "five_hour", utilization: 0.82, resetsIn: 5_400))
        .frame(width: 300, height: 180)
}
#endif
