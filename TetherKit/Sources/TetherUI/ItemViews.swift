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
        case .reasoning(let r): ReasoningView(reasoning: r)
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

struct ReasoningView: View {
    let reasoning: Item.Reasoning
    @State private var expanded = false

    var body: some View {
        if reasoning.redacted == true && reasoning.text.isEmpty {
            Label("Thought", systemImage: "brain").font(.caption).foregroundStyle(.tertiary)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                Text(reasoning.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label(expanded ? "Thinking" : (reasoning.text.split(separator: "\n").first.map(String.init) ?? "Thinking"),
                      systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
