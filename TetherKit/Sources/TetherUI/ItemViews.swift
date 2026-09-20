import SwiftUI
import TetherKit
import TetherProtocol

/// Renders one transcript item.
struct ItemView: View {
    let item: Item
    let thread: ThreadModel

    var body: some View {
        switch item {
        case .userMessage(let m): UserMessageView(message: m)
        case .agentMessage(let m):
            MarkdownView(text: m.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning(let r): ReasoningView(reasoning: r, thread: thread)
        case .toolCall(let t): ToolCallView(call: t, thread: thread)
        case .compaction(let c):
            HStack {
                VStack { Divider() }
                Label("Conversation compacted" + (c.preTokens.map { " · \(Format.tokens($0)) tokens" } ?? ""), systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                VStack { Divider() }
            }
        case .error(let e):
            Label(e.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .notice(let n): NoticeView(notice: n)
        case .unknown(let v):
            DisclosureGroup("Unknown item: \(v["type"]?.stringValue ?? "?")") {
                Text(v.pretty).font(.caption.monospaced()).textSelection(.enabled)
            }
            .font(.caption)
        }
    }
}

struct UserMessageView: View {
    let message: Item.UserMessage

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if message.synthetic == true {
                    Label(message.origin ?? "system", systemImage: "gearshape")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let t):
                        Text(t.text)
                            .textSelection(.enabled)
                            .lineLimit(message.synthetic == true ? 6 : nil)
                    case .image(let img):
                        if let data = Data(base64Encoded: img.data), let ns = NSImage(data: data) {
                            Image(nsImage: ns).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    case .fileRef(let f):
                        Label(f.path, systemImage: "doc").font(.callout)
                    case .unknown:
                        EmptyView()
                    }
                }
                if message.queued == true {
                    Text("Sent while running").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.synthetic == true ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(message.synthetic == true ? .secondary : .primary)
        }
    }
}

/// Collapsed by default — a quiet "Thought" (or "Thought for 12s") line — so the model's
/// internal monologue doesn't compete with its actual reply. While the item is still streaming
/// (it's the last item in the thread and the thread is running) it stays expanded so the text
/// is visible as it arrives, then collapses once something follows it. A person who explicitly
/// toggles it overrides that for the rest of this item's life.
struct ReasoningView: View {
    let reasoning: Item.Reasoning
    let thread: ThreadModel
    @State private var userExpanded: Bool?

    init(reasoning: Item.Reasoning, thread: ThreadModel, initiallyExpanded: Bool? = nil) {
        self.reasoning = reasoning
        self.thread = thread
        self._userExpanded = State(initialValue: initiallyExpanded)
    }

    private var isStreaming: Bool {
        thread.isRunning && thread.itemIndex(of: reasoning.id) == thread.items.count - 1
    }

    private var isExpanded: Bool { userExpanded ?? isStreaming }

    /// There's no explicit duration on the wire, so this is the closest proxy to "how long did
    /// it think": the gap between this item starting and whatever came right after it (the next
    /// item, or the turn finishing if this was the turn's last item).
    private var elapsedSeconds: Double? {
        guard !isStreaming, let index = thread.itemIndex(of: reasoning.id) else { return nil }
        let stopMs = index + 1 < thread.items.count
            ? thread.items[index + 1].createdAt
            : thread.turns.first { $0.id == reasoning.turnId }?.completedAt
        guard let stopMs, stopMs > reasoning.createdAt else { return nil }
        return (stopMs - reasoning.createdAt) / 1000
    }

    private var label: String {
        elapsedSeconds.map { "Thought for \(Format.duration($0))" } ?? "Thought"
    }

    var body: some View {
        if reasoning.redacted == true && reasoning.text.isEmpty {
            Label("Thought", systemImage: "brain").font(.caption).foregroundStyle(.tertiary)
        } else {
            DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { userExpanded = $0 })) {
                Text(reasoning.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NoticeView: View {
    let notice: Item.Notice

    var body: some View {
        let symbol = switch notice.kind {
        case "interrupted": "stop.circle"
        case "localCommandOutput": "terminal"
        case "modelFallback": "arrow.triangle.swap"
        default: "info.circle"
        }
        Label {
            Text(notice.text).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(notice.level == .warning ? AnyShapeStyle(.orange) : notice.level == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}

#if DEBUG
#Preview("User message") {
    ScrollView {
        ItemView(item: .sampleUserMessage("Can you clean up the build directory before we cut a release?", secondsAgo: 30), thread: .sampleIdleChat())
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
    }
    .frame(width: 640, height: 200)
}

#Preview("User message (synthetic)") {
    ScrollView {
        ItemView(item: .sampleUserMessage("Compacted 3 earlier turns to stay under the context limit.", secondsAgo: 30, synthetic: true, origin: "compaction"), thread: .sampleIdleChat())
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
    }
    .frame(width: 640, height: 160)
}

#Preview("Agent message") {
    ScrollView {
        ItemView(item: .sampleAgentMessage("Sure — I ran `rm -rf .build` and confirmed the workspace still builds cleanly.", secondsAgo: 10), thread: .sampleIdleChat())
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 920)
    }
    .frame(width: 640, height: 160)
}

// #Preview bodies can't have `let`/control flow, so this builds a thread where a reasoning
// item is followed by a reply a few seconds later — enough for `ReasoningView` to derive
// "Thought for Ns" — and pulls the `Item.Reasoning` back out for the previews below.
@MainActor
private func sampleFinishedReasoning() -> (Item.Reasoning, ThreadModel) {
    let thread = ThreadModel.sample(status: .idle, items: [
        .sampleUserMessage("Can you check how ThreadModel tracks turns before answering?", secondsAgo: 20),
        .sampleReasoning("Let me check ThreadModel.swift before answering, so this matches what's actually there.", secondsAgo: 14),
        .sampleAgentMessage("It keeps two parallel timelines: items and turns.", secondsAgo: 2),
    ])
    guard case .reasoning(let r) = thread.items[1] else { fatalError("expected the reasoning item") }
    return (r, thread)
}

#Preview("Reasoning (collapsed)") {
    let (reasoning, thread) = sampleFinishedReasoning()
    ScrollView {
        ReasoningView(reasoning: reasoning, thread: thread)
            .padding(28)
    }
    .frame(width: 640, height: 120)
}

#Preview("Reasoning (expanded)") {
    let (reasoning, thread) = sampleFinishedReasoning()
    ScrollView {
        ReasoningView(reasoning: reasoning, thread: thread, initiallyExpanded: true)
            .padding(28)
    }
    .frame(width: 640, height: 160)
}

#Preview("Reasoning (streaming)") {
    // The thread is still running and this is the last item — no duration yet, and it stays
    // expanded on its own (no user toggle) so the text is visible as it arrives.
    let thread = ThreadModel.sample(status: .running, items: [
        .sampleUserMessage("Can you check how ThreadModel tracks turns before answering?", secondsAgo: 6),
        .sampleReasoning("Let me check ThreadModel.swift before answering, so this matches what's actually there.", secondsAgo: 2),
    ])
    guard case .reasoning(let reasoning) = thread.items.last else { fatalError("expected the reasoning item") }
    return ScrollView {
        ReasoningView(reasoning: reasoning, thread: thread)
            .padding(28)
    }
    .frame(width: 640, height: 160)
}

#Preview("Notice") {
    ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            ItemView(item: .sampleNotice("Switched to Claude Sonnet 5 after a rate limit on Opus.", kind: "modelFallback", level: .warning, secondsAgo: 5), thread: .sampleIdleChat())
            ItemView(item: .sampleNotice("Interrupted by user.", kind: "interrupted", level: .info, secondsAgo: 5), thread: .sampleIdleChat())
            ItemView(item: .sampleNotice("$ swift build --target TetherKit", kind: "localCommandOutput", secondsAgo: 5), thread: .sampleIdleChat())
        }
        .padding(28)
    }
    .frame(width: 640, height: 220)
}

#Preview("Error item") {
    ScrollView {
        ItemView(item: .error(.init(id: "err-1", createdAt: 0, message: "The model reported an internal error and the turn could not continue.")), thread: .sampleIdleChat())
            .padding(28)
    }
    .frame(width: 640, height: 160)
}

#Preview("Full transcript") {
    let thread = ThreadModel.sampleIdleChat()
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(thread.topLevelItems, id: \.id) { item in
                ItemView(item: item, thread: thread)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: 920)
    }
    .frame(width: 760, height: 560)
}

#endif
