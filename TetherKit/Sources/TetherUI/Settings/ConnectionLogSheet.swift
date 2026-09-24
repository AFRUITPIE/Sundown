import AppKit
import SwiftUI

/// What the host said while connecting — the thing to paste into an issue when it didn't.
struct ConnectionLogSheet: View {
    let host: String
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    private var text: String { lines.joined(separator: "\n") }

    var body: some View {
        VStack(spacing: 0) {
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
                .background(.background)
            }
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(lines.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 400)
        .accessibilityLabel("Connection Log for \(host)")
    }
}

#if DEBUG
#Preview("Connection Log") {
    ConnectionLogSheet(host: "build-box", lines: [
        "$ ssh build-box ~/.tether/bin/tether-0.4.0-linux-x64 connect",
        "Installing tether-0.4.0-linux-x64 (4.2 MB)…",
        "Connected: build-box.local, claude 2.1.4 at /usr/local/bin/claude",
        "Disconnected: The operation couldn’t be completed. (TetherKit.TransportError error 1.)",
        "Reconnecting in 2s…",
    ])
}

#Preview("Connection Log (empty)") {
    ConnectionLogSheet(host: "This Mac", lines: [])
}
#endif
