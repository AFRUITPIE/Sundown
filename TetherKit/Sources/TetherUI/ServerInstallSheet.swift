import SwiftUI
import TetherKit

/// Asks before installing or updating a host's Tether server: what it downloads and where it goes,
/// and the exact command that runs there, which can be copied to run by hand instead. Nothing is
/// installed without this.
struct ServerInstallSheet: View {
    let offer: ServerOffer
    let host: String
    /// This Mac downloads it itself: there's no other Mac to fall back on.
    var isLocal = false
    let install: (ServerOffer) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(offer.question(host: host)).font(.headline)
                    Text(explanation).foregroundStyle(.secondary)
                }
            }
            Section("Runs on \(host)") {
                HStack(alignment: .firstTextBaseline) {
                    Text(offer.command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityTextContentType(.sourceCode)
                    Spacer(minLength: 8)
                    Button("Copy Command", systemImage: "doc.on.doc") { Clipboard.copy(offer.command) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy Command")
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(offer.isUpdate ? "Update" : "Install") {
                    install(offer)
                    dismiss()
                }
            }
        }
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    }

    private var explanation: String {
        let size = offer.size.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? ""
        var download = "Downloads Tether \(offer.version)\(size) from GitHub into ~/.tether/bin."
        if !isLocal { download += " If \(host) can’t reach GitHub, this Mac downloads it and copies it over." }
        switch offer.reason {
        case .missing:
            return "Tether runs your chats on \(host). \(download)"
        case .outdated(let installed):
            return "\(host) runs Tether \(installed), which is too old for this app. \(download)"
        case .newer(let installed):
            return "\(host) runs Tether \(installed). \(download) Chats that are running finish first."
        }
    }
}

extension ServerOffer {
    /// The sheet's question, and the words for its button elsewhere.
    func question(host: String) -> String {
        isUpdate ? "Update Tether on \(host)?" : "Install Tether on \(host)?"
    }

    /// The button that asks: Install… or Update…, or Try Again… after a failure.
    var askTitle: String {
        if failure != nil { return "Try Again…" }
        return isUpdate ? "Update…" : "Install…"
    }
}

extension View {
    /// Presents the question for `offer` while it's set, and installs on the host when answered.
    func serverInstallSheet(_ offer: Binding<ServerOffer?>, connection: HostConnection) -> some View {
        sheet(item: offer) { offer in
            ServerInstallSheet(offer: offer, host: connection.host.name, isLocal: connection.host.isLocal) { chosen in
                Task { await connection.installServer(chosen) }
            }
        }
    }
}

#if DEBUG
#Preview("Install Tether", traits: .fixedLayout(width: 520, height: 320)) {
    ServerInstallSheet(offer: ServerOffer(reason: .missing, platform: "linux-x64", size: 98_300_000),
                       host: "claude-box") { _ in }
}

#Preview("Update Tether (needed)", traits: .fixedLayout(width: 520, height: 320)) {
    ServerInstallSheet(offer: ServerOffer(reason: .outdated(installed: "0.4.2"), platform: "darwin-arm64"),
                       host: "This Mac", isLocal: true) { _ in }
}
#endif
