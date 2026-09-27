import AppKit
import SwiftUI
import TetherKit

/// What a host said while connecting — the thing to paste into an issue when it didn't. A window
/// of its own (Host ▸ Show Connection Log), so it can stay open beside a chat and follow along as
/// the host reconnects.
public struct ConnectionLogWindow: View {
    let app: AppModel
    let hostID: UUID?

    public init(app: AppModel, hostID: UUID?) {
        self.app = app
        self.hostID = hostID
    }

    public var body: some View {
        let connection = hostID.flatMap(app.connection)
        ConnectionLogView(host: connection?.host.name ?? "Host", lines: connection?.log ?? [])
            .navigationTitle("Connection Log")
            .navigationSubtitle(connection?.host.name ?? "")
    }
}

struct ConnectionLogView: View {
    let host: String
    let lines: [String]

    private var text: String { lines.joined(separator: "\n") }

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView("No Log", systemImage: "doc.plaintext")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                // The newest line is what's worth reading; it stays in view as more arrive.
                .defaultScrollAnchor(.bottom)
                .background(.background)
            }
        }
        .toolbar {
            Button("Copy Log", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(lines.isEmpty)
            .help("Copy Log")
        }
        .frame(minWidth: 480, minHeight: 280)
        .accessibilityLabel("Connection Log for \(host)")
    }
}

/// Host ▸ Show Connection Log, and Settings' Show…: the log window for a host.
struct ShowConnectionLogButton: View {
    let hostID: UUID
    var title = "Show Connection Log"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: ConnectionLogWindow.id, value: hostID) }
    }
}

extension ConnectionLogWindow {
    public static let id = "connection-log"
}

#if DEBUG
#Preview("Connection Log") {
    ConnectionLogView(host: "build-box", lines: [
        "$ ssh build-box ~/.tether/bin/tether-0.4.0-linux-x64 connect",
        "Installing tether-0.4.0-linux-x64 (4.2 MB)…",
        "Connected: build-box.local, claude 2.1.4 at /usr/local/bin/claude",
        "Disconnected: The operation couldn’t be completed. (TetherKit.TransportError error 1.)",
        "Reconnecting in 2s…",
    ])
    .frame(width: 620, height: 400)
}

#Preview("Connection Log (empty)") {
    ConnectionLogView(host: "This Mac", lines: [])
        .frame(width: 620, height: 400)
}
#endif
