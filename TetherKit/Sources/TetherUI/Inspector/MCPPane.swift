import SwiftUI
import TetherKit

/// The MCP servers this chat's Claude Code has, and whether they came up. Reads `thread.info`
/// only, which changes once per session rather than per delta.
struct MCPPane: View {
    let thread: ThreadModel

    var body: some View {
        let servers = thread.info?.mcpServers ?? []
        if servers.isEmpty {
            InspectorEmptyState("No MCP Servers", symbol: "puzzlepiece.extension")
        } else {
            Form {
                Section {
                    ForEach(servers, id: \.name) { s in
                        LabeledContent(s.name) {
                            Label(s.status.humanized, systemImage: symbol(for: s.status))
                                .foregroundStyle(tint(for: s.status))
                        }
                    }
                }
            }
        }
    }

    /// Status carries a symbol as well as a color, so it doesn't rely on color alone.
    private func symbol(for status: String) -> String {
        switch status {
        case "connected", "ready": return "checkmark.circle.fill"
        case "connecting", "pending": return "clock"
        case "failed", "error": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private func tint(for status: String) -> Color {
        switch status {
        case "connected", "ready": return .green
        case "failed", "error": return .red
        default: return .secondary
        }
    }
}

#if DEBUG
#Preview("MCP") {
    inspectorPreview {
        ThreadInspector(thread: .sampleWithTasks(), connection: .sample(), pane: .mcp)
    }
}

/// A chat whose Claude Code has no MCP servers configured — same state as one that hasn't
/// reported yet, and the title says all there is to say about either.
#Preview("MCP (none)") {
    inspectorPreview {
        ThreadInspector(thread: .sampleIdleChat(), connection: .sample(), pane: .mcp)
    }
}
#endif
