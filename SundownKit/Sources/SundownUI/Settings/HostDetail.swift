import SwiftUI
import SundownKit

/// One host's settings. Everything applies as it is changed — there is no Save button in a macOS
/// settings window — so the only thing this view holds is which sheet is open.
struct HostDetail: View {
    let host: HostConfig
    let connection: HostConnection?
    let update: (HostConfig) -> Void
    @State private var editingEnvironment = false

    var body: some View {
        Form {
            Section {
                CommittingTextField("Name", value: host.name) { name in
                    var updated = host
                    updated.name = name
                    update(updated)
                }
                // Nothing stands in for this on the local host: its name is the only field, and
                // the machine it runs on is named under Connection.
                if let destination = host.sshDestination {
                    CommittingTextField("Destination", value: destination, prompt: "Alias or user@host") { value in
                        var updated = host
                        updated.kind = .ssh(destination: value)
                        update(updated)
                    }
                    .autocorrectionDisabled()
                }
            }
            connectionSection
            advancedSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingEnvironment) {
            EnvironmentVariablesSheet(environment: host.env) { environment in
                var updated = host
                updated.env = environment
                update(updated)
            }
        }
    }

    // MARK: sections

    @ViewBuilder private var connectionSection: some View {
        if let connection {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        // The state is the row's point; the button gives way to it.
                        HostStatusLabel(state: connection.state)
                            .layoutPriority(1)
                        ConnectButton(connection: connection)
                    }
                }
                if let server = connection.serverInfo {
                    LabeledContent("Machine", value: "\(server.host.hostname) · \(platformName(server.host.platform)) \(server.host.arch)")
                    LabeledContent("Claude Code", value: server.claude.version)
                        .help(server.claude.path)
                }
                if let account = connection.account {
                    if let provider = account.apiProvider { LabeledContent("Provider", value: providerName(provider)) }
                    if let email = account.email { LabeledContent("Account", value: email) }
                }
            } header: {
                Text("Connection")
            } footer: {
                // The one thing about a connection the user can act on.
                if let message = connection.state.failureMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("host.connectionError")
                }
            }
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            // The field is monospaced, the label isn't: a command is code, its name is not.
            LabeledContent("Server Command") {
                CommittingTextField("Server Command", value: host.serverCommand ?? "",
                                    prompt: "Automatic", allowsEmpty: true) { command in
                    var updated = host
                    updated.serverCommand = command.isEmpty ? nil : command
                    update(updated)
                }
                .labelsHidden()
                .font(.body.monospaced())
                .autocorrectionDisabled()
            }
            LabeledContent("Environment Variables") {
                HStack(spacing: 10) {
                    Text(host.env.isEmpty ? "None" : host.env.count.formatted())
                        .foregroundStyle(.secondary)
                    Button("Edit…") { editingEnvironment = true }
                }
            }
            if connection != nil {
                LabeledContent("Connection Log") {
                    ShowConnectionLogButton(hostID: host.id, title: "Show…")
                }
            }
        }
    }

    /// Node's own words for a platform, as a person would write them.
    private func platformName(_ platform: String) -> String {
        switch platform {
        case "darwin": "macOS"
        case "linux": "Linux"
        case "win32": "Windows"
        default: platform.humanized
        }
    }

    private func providerName(_ provider: String) -> String {
        switch provider {
        case "firstParty": "Anthropic"
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case "foundry": "Microsoft Foundry"
        case "gateway": "Gateway"
        default: provider.humanized
        }
    }
}

/// A text field that applies on Return and when focus leaves, never per keystroke: each commit
/// can reconnect the host. A value that isn't storable puts the old one back.
struct CommittingTextField: View {
    private let title: String
    private let value: String
    private let prompt: String?
    private let allowsEmpty: Bool
    private let commit: (String) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(_ title: String, value: String, prompt: String? = nil, allowsEmpty: Bool = false,
         commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.prompt = prompt
        self.allowsEmpty = allowsEmpty
        self.commit = commit
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .focused($isFocused)
            .onSubmit(commitEdit)
            .onChange(of: isFocused) { _, focused in if !focused { commitEdit() } }
            // The host can change under an idle field (a rename elsewhere, a reverted commit).
            .onChange(of: value) { _, new in if !isFocused { text = new } }
    }

    private func commitEdit() {
        guard let committed = HostField.commit(text, current: value, allowsEmpty: allowsEmpty) else {
            text = value
            return
        }
        text = committed
        commit(committed)
    }
}

enum HostField {
    /// What to store, or nil when there is nothing to store: a name or destination that is empty
    /// after trimming is refused, and an unchanged value isn't worth a reconnect.
    static func commit(_ input: String, current: String, allowsEmpty: Bool = false) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmpty || !trimmed.isEmpty else { return nil }
        return trimmed == current ? nil : trimmed
    }
}

#if DEBUG
#Preview("Host Detail (this Mac)") {
    HostDetail(host: .local, connection: .sample()) { _ in }
        .frame(width: 472, height: 440)
}

#Preview("Host Detail (SSH)") {
    let connection = HostConnection.sampleConnectedSSH()
    return HostDetail(host: connection.host, connection: connection) { _ in }
        .frame(width: 472, height: 440)
}

#Preview("Host Detail (failed)") {
    let connection = HostConnection.sampleFailed()
    return HostDetail(host: connection.host, connection: connection) { _ in }
        .frame(width: 472, height: 440)
}
#endif
