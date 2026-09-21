import SwiftUI
import TetherKit
import TetherProtocol

/// General, Chats and Hosts panes; hosts are managed inside their own pane.
public struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage("tether.settingsPane") private var storedSelection = SettingsDestination.general.storedValue

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        TabView(selection: selection) {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsDestination.general)
            NewChatSettings(app: app)
                .tabItem { Label("Chats", systemImage: "plus.bubble") }
                .tag(SettingsDestination.chats)
            HostsSettings(app: app)
                .tabItem { Label("Hosts", systemImage: "network") }
                .tag(SettingsDestination.hosts)
        }
        .frame(width: 660, height: 400)
    }

    private var selection: Binding<SettingsDestination> {
        Binding(
            get: { SettingsDestination(storedValue: storedSelection) },
            set: { storedSelection = $0.storedValue }
        )
    }
}

enum SettingsDestination: Hashable {
    case general
    case chats
    case hosts

    init(storedValue: String) {
        switch storedValue {
        case "newChats", "chats": self = .chats
        case "hosts": self = .hosts
        default: self = storedValue.hasPrefix("host:") ? .hosts : .general
        }
    }

    var storedValue: String {
        switch self {
        case .general: "general"
        case .chats: "chats"
        case .hosts: "hosts"
        }
    }
}

/// The transcript width as a View submenu with the current value checked.
public struct TranscriptWidthCommands: View {
    @Bindable var app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Picker("Transcript Width", selection: $app.transcriptWidth) {
            ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
        }
    }
}

struct GeneralSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("Transcript") {
                Picker("Width", selection: $app.transcriptWidth) {
                    ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct NewChatSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("New Chat Defaults") {
                defaultModelPicker
                Picker("Reasoning", selection: Binding(
                    get: { app.defaultEffort ?? "" },
                    set: { app.defaultEffort = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Automatic").tag("")
                    ForEach(EffortLevel.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0.rawValue)
                    }
                }
                Picker("Permissions", selection: $app.defaultPermissionMode) {
                    Text("Ask").tag(PermissionMode.default.rawValue)
                    Text("Allow Edits").tag(PermissionMode.acceptEdits.rawValue)
                    Text("Plan Only").tag(PermissionMode.plan.rawValue)
                    Text("Automatic").tag(PermissionMode.auto.rawValue)
                    Text("Deny").tag(PermissionMode.dontAsk.rawValue)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Chats")
    }

    private var models: [ModelInfo] { app.connection(HostConfig.local.id)?.models ?? [] }

    @ViewBuilder private var defaultModelPicker: some View {
        if models.isEmpty {
            LabeledContent("Model") {
                Text(app.defaultModel ?? "Not Connected")
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
        } else {
            Picker("Model", selection: Binding(
                get: { models.concreteValue(for: app.defaultModel) },
                set: { app.defaultModel = $0 }
            )) {
                ForEach(models.concrete, id: \.value) {
                    Text($0.shortName).tag(Optional($0.value))
                }
                // Preserve a Bedrock or otherwise unlisted model ID already stored by the user.
                if let model = app.defaultModel,
                   !models.contains(where: { $0.value == model || $0.resolvedModel == model }) {
                    Text(model).tag(Optional(model))
                }
            }
        }
    }
}

struct HostsSettings: View {
    @Bindable var app: AppModel
    @State private var selectedHostID: UUID? = HostConfig.local.id
    @State private var addingSSH = false
    @State private var removingHost: HostConfig?

    private var selectedHost: HostConfig? {
        app.hosts.first { $0.id == selectedHostID } ?? app.hosts.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Hosts").font(.headline)
                    Spacer()
                    Button { addingSSH = true } label: { Image(systemName: "plus") }
                        .help("Add SSH Host")
                    Button {
                        removingHost = selectedHost.flatMap { $0.isLocal ? nil : $0 }
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedHost?.isLocal != false)
                    .help("Remove Host")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .frame(height: 42)
                Divider()
                List(app.hosts, selection: $selectedHostID) { host in
                    HostRow(host: host, connection: app.connection(host.id))
                        .tag(host.id)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 190, idealWidth: 210, maxWidth: 240)

            if let host = selectedHost {
                HostEditor(host: host, connection: app.connection(host.id)) { app.updateHost($0) }
                    .id(host.id)
                    .frame(minWidth: 430)
            } else {
                ContentUnavailableView("No Hosts", systemImage: "network")
            }
        }
        .navigationTitle("Hosts")
        .sheet(isPresented: $addingSSH) {
            AddSSHHostSheet { host in
                app.addHost(host)
                selectedHostID = host.id
            }
        }
        .alert("Remove Host?", isPresented: Binding(
            get: { removingHost != nil },
            set: { if !$0 { removingHost = nil } }
        ), presenting: removingHost) { host in
            Button("Remove", role: .destructive) {
                app.removeHost(host.id)
                selectedHostID = HostConfig.local.id
                removingHost = nil
            }
            Button("Cancel", role: .cancel) { removingHost = nil }
        } message: { host in
            Text("Remove “\(host.name)” from Tether? Chats and configuration on the host are unchanged.")
        }
    }
}

struct HostRow: View {
    let host: HostConfig
    let connection: HostConnection?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: host.isLocal ? "laptopcomputer" : "network")
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).lineLimit(1)
                Text(host.sshDestination ?? "This Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(statusText)
        }
    }

    private var statusText: String {
        guard let connection else { return "Disconnected" }
        switch connection.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .failed: return "Connection Failed"
        case .disconnected: return "Disconnected"
        }
    }

    private var statusColor: Color {
        guard let connection else { return .secondary }
        switch connection.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}

struct HostEditor: View {
    @State private var host: HostConfig
    @State private var savedHost: HostConfig
    let connection: HostConnection?
    let save: (HostConfig) -> Void
    @State private var envRows: [EnvRow]

    struct EnvRow: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(host: HostConfig, connection: HostConnection?, save: @escaping (HostConfig) -> Void) {
        self._host = State(initialValue: host)
        self._savedHost = State(initialValue: host)
        self.connection = connection
        self.save = save
        self._envRows = State(initialValue: host.env.sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.headline)
                    Text(host.sshDestination ?? "This Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDirty {
                    Button("Revert", action: revert)
                    Button("Save", action: saveChanges)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            Divider()
            Form {
                Section("Host") {
                    TextField("Name", text: $host.name)
                    if host.isLocal {
                        LabeledContent("Type", value: "This Mac")
                    } else {
                        TextField("SSH Destination", text: Binding(
                            get: { host.sshDestination ?? "" },
                            set: { host.kind = .ssh(destination: $0) }
                        ))
                    }
                }
                if let connection {
                    Section("Connection") {
                        LabeledContent("Status") {
                            HStack(spacing: 10) {
                                Text(statusText(connection.state)).foregroundStyle(.secondary)
                                Button(connection.state == .connected ? "Reconnect" : "Connect") {
                                    Task {
                                        if connection.state == .connected { await connection.reconnect() }
                                        else { await connection.connect() }
                                    }
                                }
                            }
                        }
                        if let server = connection.serverInfo {
                            LabeledContent("Machine", value: "\(server.host.hostname) · \(server.host.platform) · \(server.host.arch)")
                            LabeledContent("Claude", value: server.claude.version)
                        }
                        if let account = connection.account {
                            LabeledContent("Provider", value: providerName(account.apiProvider))
                            if let email = account.email { LabeledContent("Account", value: email) }
                        }
                    }
                }
                Section("Advanced") {
                    DisclosureGroup("Environment Variables") {
                        ForEach($envRows) { $row in
                            HStack {
                                TextField("NAME", text: $row.key).font(.body.monospaced())
                                TextField("value", text: $row.value).font(.body.monospaced())
                                Button { envRows.removeAll { $0.id == row.id } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Variable", systemImage: "plus") {
                            envRows.append(.init(key: "", value: ""))
                        }
                    }
                    DisclosureGroup("Server") {
                        TextField("Command", text: Binding(
                            get: { host.serverCommand ?? "" },
                            set: { host.serverCommand = $0.isEmpty ? nil : $0 }
                        ), prompt: Text("Automatic"))
                        .font(.body.monospaced())
                        if let connection {
                            LabeledContent("Executable") {
                                Text(connection.serverInfo?.claude.path ?? "—")
                                    .font(.caption.monospaced())
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            DisclosureGroup("Connection Log") {
                                ScrollView {
                                    Text(connection.log.suffix(100).joined(separator: "\n"))
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 120)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var draftHost: HostConfig {
        var draft = host
        draft.env = Dictionary(envRows.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
                               uniquingKeysWith: { $1 })
        return draft
    }

    private var isDirty: Bool { draftHost != savedHost }

    private func saveChanges() {
        let draft = draftHost
        host = draft
        savedHost = draft
        save(draft)
    }

    private func revert() {
        host = savedHost
        envRows = savedHost.env.sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) }
    }

    private func statusText(_ state: HostConnection.State) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting(let message): return message
        case .failed(let message): return "Failed: \(message)"
        case .disconnected: return "Disconnected"
        }
    }

    private func providerName(_ provider: String?) -> String {
        switch provider {
        case "firstParty": return "Anthropic"
        case "bedrock": return "Amazon Bedrock"
        case "vertex": return "Google Vertex AI"
        case "foundry": return "Microsoft Foundry"
        case "gateway": return "Gateway"
        case .some(let value): return value
        case nil: return "—"
        }
    }
}

struct AddSSHHostSheet: View {
    let add: (HostConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var name = ""
    @State private var aliases: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if !aliases.isEmpty {
                        Picker("SSH Config", selection: $destination) {
                            Text("Choose…").tag("")
                            ForEach(aliases, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Destination", text: $destination,
                              prompt: Text("Alias or user@host"))
                    TextField("Name", text: $name,
                              prompt: Text(destination.isEmpty ? "Optional" : destination))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    add(HostConfig(name: name.isEmpty ? destination : name,
                                   kind: .ssh(destination: destination)))
                    dismiss()
                }
                .disabled(destination.isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .navigationTitle("Add SSH Host")
        .frame(width: 440)
        .task {
            aliases = await Task.detached(priority: .userInitiated) {
                SSHConfig.hostAliases()
            }.value
        }
    }
}

#if DEBUG
#Preview("SettingsView") {
    SettingsView(app: .sample())
}

#Preview("GeneralSettings") {
    GeneralSettings(app: .sample())
        .frame(width: 520, height: 360)
}

#Preview("NewChatSettings") {
    NewChatSettings(app: .sample())
        .frame(width: 520, height: 360)
}

#Preview("HostsSettings") {
    HostsSettings(app: .sample())
        .frame(width: 660, height: 400)
}

#Preview("HostEditor") {
    let connection = HostConnection.sample()
    HostEditor(host: connection.host, connection: connection) { _ in }
        .frame(width: 460, height: 500)
}

#Preview("HostEditor (SSH)") {
    let host = HostConfig(name: "build-box", kind: .ssh(destination: "build-box"),
                          env: ["AWS_PROFILE": "tether", "AWS_REGION": "us-west-2"])
    HostEditor(host: host, connection: .sampleFailed()) { _ in }
        .frame(width: 460, height: 500)
}

#Preview("AddSSHHostSheet") {
    AddSSHHostSheet { _ in }
}

#endif
