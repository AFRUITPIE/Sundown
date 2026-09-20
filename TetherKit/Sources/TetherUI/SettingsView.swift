import SwiftUI
import TetherKit
import TetherProtocol

public struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage("tether.settingsPane") private var selectedPane = SettingsPane.general

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        TabView(selection: $selectedPane) {
            GeneralSettings(app: app)
                .frame(width: 540, height: 330)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)
            HostsSettings(app: app)
                .frame(width: 760, height: 540)
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(SettingsPane.hosts)
        }
    }
}

private enum SettingsPane: String {
    case general
    case hosts
}

/// The transcript-width choice as a View menu item. A submenu of mutually exclusive options is
/// what a menu-bar picker renders as, so the current width carries a checkmark.
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
            Section {
                Picker("Transcript Width", selection: $app.transcriptWidth) {
                    ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("How wide messages are allowed to get. Narrow keeps lines short enough to read comfortably; the wider settings wrap code and diffs less.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                defaultModelPicker
                Picker("Effort", selection: Binding(get: { app.defaultEffort ?? "" }, set: { app.defaultEffort = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic").tag("")
                    ForEach(EffortLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                Picker("Permission Mode", selection: $app.defaultPermissionMode) {
                    ForEach([PermissionMode.default, .acceptEdits, .plan, .auto, .dontAsk], id: \.self) { Text($0.longLabel).tag($0.rawValue) }
                }
            } header: {
                Text("New Chats")
            } footer: {
                Text("Models come from Claude Code on this Mac. You can change these controls for an individual chat from its toolbar.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(nil)
            }
        }
        // Grouped so the section headers and footers render as such instead of as loose body
        // text between the rows.
        .formStyle(.grouped)
    }

    /// The models Claude Code on this Mac reports. The default is one of them by name — the app
    /// can't ask the CLI which model it would otherwise choose, so "whatever it picks" isn't an
    /// answer it could show.
    private var models: [ModelInfo] { app.connection(HostConfig.local.id)?.models ?? [] }

    @ViewBuilder private var defaultModelPicker: some View {
        if models.isEmpty {
            LabeledContent("Model") {
                Text(app.defaultModel ?? "Not connected")
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
        } else {
            Picker("Model", selection: Binding(get: { models.concreteValue(for: app.defaultModel) },
                                                set: { app.defaultModel = $0 })) {
                ForEach(models.concrete, id: \.value) { Text($0.shortName).tag(Optional($0.value)) }
                // A Bedrock or otherwise unlisted ID set earlier stays selectable.
                if let m = app.defaultModel, !models.contains(where: { $0.value == m || $0.resolvedModel == m }) {
                    Text(m).tag(Optional(m))
                }
            }
        }
    }
}

struct HostsSettings: View {
    @Bindable var app: AppModel
    @State private var selected: UUID? = HostConfig.local.id
    @State private var addingSSH = false
    @State private var removingHost: HostConfig?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(app.hosts, selection: $selected) { h in
                    Label(h.name, systemImage: h.isLocal ? "laptopcomputer" : "network").tag(h.id)
                }
                HStack {
                    Button { addingSSH = true } label: { Image(systemName: "plus") }
                        .help("Add SSH Host")
                    Button {
                        removingHost = app.hosts.first { $0.id == selected }
                    } label: { Image(systemName: "minus") }
                        .disabled(selected == HostConfig.local.id)
                        .help("Remove Host")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 180, maxWidth: 220)
            if let s = selected, let h = app.hosts.first(where: { $0.id == s }) {
                HostEditor(host: h, connection: app.connection(h.id)) { app.updateHost($0) }.id(h.id)
            } else {
                Text("Select a host").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $addingSSH) {
            AddSSHHostSheet { h in
                app.addHost(h)
                selected = h.id
            }
        }
        .alert("Remove Host?", isPresented: Binding(
            get: { removingHost != nil },
            set: { if !$0 { removingHost = nil } }
        ), presenting: removingHost) { host in
            Button("Remove", role: .destructive) {
                app.removeHost(host.id)
                selected = HostConfig.local.id
                removingHost = nil
            }
            Button("Cancel", role: .cancel) { removingHost = nil }
        } message: { host in
            Text("Remove “\(host.name)” from Tether? Chats and Claude Code configuration on that host are not deleted.")
        }
    }
}

struct HostEditor: View {
    @State var host: HostConfig
    let connection: HostConnection?
    let save: (HostConfig) -> Void
    @State private var envRows: [EnvRow] = []

    struct EnvRow: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        Form {
            TextField("Name", text: $host.name)
            if let d = host.sshDestination {
                LabeledContent("SSH destination", value: d)
            } else {
                LabeledContent("Kind", value: "This Mac")
            }
            Section {
                ForEach($envRows) { $row in
                    HStack {
                        TextField("NAME", text: $row.key).font(.body.monospaced())
                        TextField("value", text: $row.value).font(.body.monospaced())
                        Button { envRows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Variable", systemImage: "plus") { envRows.append(.init(key: "", value: "")) }
            } header: {
                Text("Environment")
            } footer: {
                Text("Overrides the host’s login-shell environment for Claude Code. For example, use AWS_PROFILE and AWS_REGION for Bedrock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                TextField("Server Command", text: Binding(get: { host.serverCommand ?? "" }, set: { host.serverCommand = $0.isEmpty ? nil : $0 }), prompt: Text("bun run ~/Code/tether-server/src/cli.ts connect"))
                    .font(.body.monospaced())
            }
            if let c = connection {
                Section("Connection") {
                    LabeledContent("Status", value: statusText(c.state))
                    if let s = c.serverInfo {
                        LabeledContent("Host", value: "\(s.host.hostname) (\(s.host.platform)/\(s.host.arch))")
                        LabeledContent("Claude", value: s.claude.version)
                        LabeledContent("Executable") {
                            Text(s.claude.path)
                                .font(.caption.monospaced())
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    if let a = c.account {
                        LabeledContent("Provider", value: a.apiProvider ?? "?")
                        if let e = a.email { LabeledContent("Account", value: e) }
                    }
                    DisclosureGroup("Log") {
                        ScrollView {
                            Text(c.log.suffix(100).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Save & Reconnect") {
                    host.env = Dictionary(envRows.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
                    save(host)
                    if let c = connection { Task { await c.reconnect() } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .onAppear { envRows = host.env.sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) } }
    }

    private func statusText(_ s: HostConnection.State) -> String {
        switch s {
        case .connected: return "Connected"
        case .connecting(let m): return m
        case .failed(let m): return "Failed: \(m)"
        case .disconnected: return "Disconnected"
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Add SSH host").font(.headline)
            Text("Tether uses your ssh config, keys and agent (non-interactive). The first `claude` on the remote PATH is used; the server installs itself in ~/.tether.")
                .font(.caption).foregroundStyle(.secondary)
            if !aliases.isEmpty {
                Picker("From ~/.ssh/config", selection: $destination) {
                    Text("Choose…").tag("")
                    ForEach(aliases, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Destination (alias or user@host)", text: $destination)
            TextField("Display name", text: $name, prompt: Text(destination.isEmpty ? "Name" : destination))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    add(HostConfig(name: name.isEmpty ? destination : name, kind: .ssh(destination: destination)))
                    dismiss()
                }
                .disabled(destination.isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
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
        .frame(width: 540, height: 330)
}

#Preview("HostsSettings") {
    HostsSettings(app: .sample())
        .frame(width: 760, height: 540)
}

#Preview("HostEditor") {
    let connection = HostConnection.sample()
    HostEditor(host: connection.host, connection: connection) { _ in }
        .frame(width: 460, height: 500)
}

#Preview("HostEditor (SSH)") {
    let host = HostConfig(name: "build-box", kind: .ssh(destination: "build-box"), env: ["AWS_PROFILE": "tether", "AWS_REGION": "us-west-2"])
    HostEditor(host: host, connection: .sampleFailed()) { _ in }
        .frame(width: 460, height: 500)
}

#Preview("AddSSHHostSheet") {
    AddSSHHostSheet { _ in }
}

#endif
