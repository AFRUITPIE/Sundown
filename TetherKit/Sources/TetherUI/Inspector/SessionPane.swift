import SwiftUI
import TetherKit
import TetherProtocol

/// What this chat is costing and running on. Owns the context-usage fetch, so the daemon is asked
/// only while this pane is on screen.
struct SessionPane: View {
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
                Button("Refresh") { Task { await refresh() } }
                    .disabled(usage.isLoading)
            }
            if let limit = thread.rateLimit {
                Section("Plan Usage") {
                    if let used = limit.utilization {
                        Gauge(value: min(used, 1)) {
                            Text(limit.name.capitalized)
                        } currentValueLabel: {
                            Text("\(Int((used * 100).rounded()))%")
                        }
                        // The accent color until the limit is near.
                        .tint(limit.status == .allowed ? nil : limit.status == .warning ? .orange : .red)
                    }
                    if let reset = limit.resetsAt {
                        LabeledContent("Resets", value: reset.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Section("Cost") {
                LabeledContent("Total", value: Format.cost(thread.totalCostUsd))
                if let last = thread.turns.last?.result {
                    LabeledContent("Last Turn", value: Format.cost(last.totalCostUsd))
                    LabeledContent("Duration", value: Format.duration(last.durationMs / 1000))
                }
            }
            if let info = thread.info {
                Section("Chat") {
                    LabeledContent("Status", value: info.status.label)
                    LabeledContent("Directory") { Text(info.cwd.abbreviatingHome).truncationMode(.middle) }
                    if let v = info.claudeCodeVersion { LabeledContent("Claude Code", value: v) }
                    if let o = info.outputStyle { LabeledContent("Output Style", value: o) }
                    LabeledContent("Thread ID") { Text(info.threadId).textSelection(.enabled).font(.caption.monospaced()).truncationMode(.middle) }
                }
            }
        }
        // Keyed on the thread too, or two chats share a stale result; and on the last finished
        // turn, since the context only settles when a turn ends.
        .task(id: Key(threadId: thread.id, turn: thread.lastFinishedTurn)) {
            guard fetchesUsage else { return }
            await refresh()
        }
    }

    private struct Key: Equatable { let threadId: String; let turn: String? }

    @ViewBuilder private func contextBody(_ u: JSONValue?) -> some View {
        if let u {
            let total = u["totalTokens"]?.doubleValue ?? 0
            let limit = u["maxTokens"]?.doubleValue ?? u["rawMaxTokens"]?.doubleValue ?? 0
            if limit > 0 {
                Gauge(value: min(total / limit, 1)) {
                    Text("Used")
                } currentValueLabel: {
                    Text("\(Format.tokens(total)) of \(Format.tokens(limit))")
                }
            }
            ForEach(u["categories"]?.arrayValue ?? [], id: \.self) { c in
                LabeledContent(c.string("name") ?? "", value: Format.tokens(c["tokens"]?.doubleValue ?? 0))
            }
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
            usage = .ready(try await connection.contextUsage(thread))
        } catch is CancellationError {
            // Superseded by a newer refresh; that one owns the state from here.
        } catch {
            usage = .failed(error.localizedDescription)
        }
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
        ["name": "System prompt", "tokens": 3_100],
        ["name": "Tools", "tokens": 12_600],
        ["name": "Messages", "tokens": 61_400],
        ["name": "Free space", "tokens": 115_700],
    ],
]

/// One pane on its own, dressed exactly as the shell dresses it.
@MainActor
private func sessionPreview(_ usage: Loaded<JSONValue?>) -> some View {
    inspectorPreview {
        SessionPane(thread: .sampleIdleChat(), connection: .sample(), usage: usage)
            .inspectorPaneStyle()
    }
}

/// The live pane: this preview's connection has no loaded thread, so it shows that state.
#Preview("Session") {
    inspectorPreview {
        ThreadInspector(thread: .sampleWithTasks(), connection: .sample(), pane: .constant(.session))
    }
}

#Preview("Session (context loaded)") {
    sessionPreview(.ready(sampleContextUsage))
}

#Preview("Session (no context data)") {
    sessionPreview(.ready(nil))
}

#Preview("Session (loading)") {
    sessionPreview(.loading)
}

#Preview("Session (usage failed)") {
    sessionPreview(.failed("The chat is no longer running on this host."))
}
#endif
