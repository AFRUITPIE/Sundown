import SwiftUI
import SundownKit
import TetherProtocol

/// The MCP servers this chat's Claude Code has, whether they came up, and what can be done about
/// one that didn't: reconnect it, or turn it off or on for this chat. What `thread.info` reported
/// at the start is shown until Claude Code is asked for the current state.
struct MCPPane: View {
    let thread: ThreadModel
    var connection: HostConnection?
    @State private var live: [McpServerStatus]?
    /// The server an action is running for.
    @State private var working: String?

    private var servers: [McpServerStatus] { live ?? thread.info?.mcpServers ?? [] }

    var body: some View {
        Group {
            if servers.isEmpty {
                PaneEmptyState("No MCP Servers", symbol: "puzzlepiece.extension")
            } else {
                Form {
                    Section {
                        ForEach(servers, id: \.name) { row($0) }
                    } footer: {
                        if servers.contains(where: { $0.status == "needs-auth" }) {
                            Text("Sign in with /mcp in Claude Code.")
                        }
                    }
                }
            }
        }
        .task(id: thread.info?.mcpServers) { await refresh() }
    }

    private func row(_ server: McpServerStatus) -> some View {
        LabeledContent {
            if working == server.name {
                ProgressView().controlSize(.small)
            } else if server.status == "failed" {
                // The one state with something to do about it here, so it's a button, not just words.
                Button("Reconnect") { run(server.name) { await $0.reconnectMCP(thread, server.name) } }
                    .controlSize(.small)
                    .help(server.error ?? "Try connecting to this server again")
            } else {
                Label(Self.statusLabel(server.status), systemImage: symbol(for: server.status))
                    .foregroundStyle(tint(for: server.status))
            }
        } label: {
            Text(server.name)
            if let detail = detail(server) { Text(detail) }
        }
        // Only when the row doesn't already say it: a failed server shows Reconnect instead.
        .accessibilityValue(server.status == "failed" ? Self.statusLabel(server.status) : "")
        .contextMenu { actions(server) }
        .accessibilityActions { actions(server) }
    }

    @ViewBuilder private func actions(_ server: McpServerStatus) -> some View {
        if server.status != "disabled" {
            Button("Reconnect") { run(server.name) { await $0.reconnectMCP(thread, server.name) } }
        }
        if server.status == "disabled" {
            Button("Turn On") { run(server.name) { await $0.setMCP(thread, server.name, enabled: true) } }
        } else {
            Button("Turn Off for This Chat") { run(server.name) { await $0.setMCP(thread, server.name, enabled: false) } }
        }
    }

    /// The error, or how many tools it gave Claude.
    private func detail(_ server: McpServerStatus) -> String? {
        if let error = server.error, !error.isEmpty { return error }
        if let tools = server.toolCount, server.status == "connected" {
            return tools == 1 ? "1 tool" : "\(Int(tools)) tools"
        }
        return nil
    }

    private func run(_ name: String, _ action: @escaping (HostConnection) async -> Void) {
        guard let connection else { return }
        working = name
        Task {
            await action(connection)
            await refresh()
            working = nil
        }
    }

    private func refresh() async {
        guard let connection, let servers = await connection.mcpServers(thread) else { return }
        live = servers
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "connected": "Connected"
        case "failed": "Failed"
        case "needs-auth": "Needs Sign-In"
        case "pending": "Connecting"
        case "disabled": "Off"
        default: status.humanized
        }
    }

    /// Status carries a symbol as well as a color, so it doesn't rely on color alone.
    private func symbol(for status: String) -> String {
        switch status {
        case "connected", "ready": return "checkmark.circle.fill"
        case "connecting", "pending": return "clock"
        case "failed", "error": return "exclamationmark.triangle.fill"
        case "needs-auth": return "person.badge.key"
        case "disabled": return "minus.circle"
        default: return "circle"
        }
    }

    private func tint(for status: String) -> Color {
        switch status {
        case "connected", "ready": return .green
        case "failed", "error": return .red
        case "needs-auth": return .orange
        default: return .secondary
        }
    }
}

#if DEBUG
#Preview("MCP") {
    MCPPane(thread: .sampleWithTasks(), connection: .sample())
        .paneStyle()
        .frame(width: 360, height: 320)
}

/// A chat whose Claude Code has no MCP servers configured — same state as one that hasn't
/// reported yet, and the title says all there is to say about either.
#Preview("MCP (none)") {
    MCPPane(thread: .sampleIdleChat(), connection: .sample())
        .paneStyle()
        .frame(width: 360, height: 320)
}
#endif
