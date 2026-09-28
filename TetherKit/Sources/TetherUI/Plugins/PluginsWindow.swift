import SwiftUI
import TetherKit
import TetherProtocol

/// A host's Claude Code plugins (Host ▸ Plugins…): the installed ones, on or off, and what its
/// marketplaces offer. Installing runs the host's `claude plugin install`; one that needs a command
/// accepted says so, to be finished in Terminal.
public struct PluginsWindow: View {
    let app: AppModel
    let hostID: UUID?
    @State private var catalog: Loaded<PluginCatalog> = .loading
    @State private var search = ""
    @State private var folder: String?
    @State private var working: String?
    @State private var error: String?
    @State private var uninstalling: InstalledPlugin?

    public init(app: AppModel, hostID: UUID?) {
        self.app = app
        self.hostID = hostID
    }

    /// Seeded, for a preview.
    init(app: AppModel, hostID: UUID?, catalog: PluginCatalog) {
        self.app = app
        self.hostID = hostID
        _catalog = State(initialValue: .ready(catalog))
        fetches = false
    }

    private var fetches = true

    public static let id = "plugins"

    private var connection: HostConnection? { hostID.flatMap(app.connection) }

    public var body: some View {
        decorated
            .alert("Couldn’t Change the Plugin", isPresented: showingError, presenting: error) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
            .confirmationDialog(uninstallTitle, isPresented: showingUninstall, titleVisibility: .visible,
                                presenting: uninstalling) { plugin in
                Button("Uninstall", role: .destructive) { uninstall(plugin) }
            } message: { _ in
                Text("New chats won’t have its skills, agents or commands.")
            }
            .frame(minWidth: 560, minHeight: 420)
    }

    private var decorated: some View {
        content
            .navigationTitle("Plugins")
            .navigationSubtitle(connection?.host.name ?? "")
            .searchable(text: $search, prompt: "Search Plugins")
            .toolbar { toolbar }
            .task(id: folder) { await reload() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Project", selection: $folder) {
                Text("No Project").tag(String?.none)
                ForEach(connection?.projects.prefix(15) ?? [], id: \.cwd) { Text($0.cwd.lastPathComponent).tag(Optional($0.cwd)) }
            }
            .help("Project")
        }
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
        }
    }

    private var showingError: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }

    private var showingUninstall: Binding<Bool> {
        Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })
    }

    private var uninstallTitle: String { "Uninstall \(uninstalling?.name ?? "")?" }

    private func uninstall(_ plugin: InstalledPlugin) {
        change(plugin.id) { try await $0.uninstallPlugin(plugin, cwd: folder) }
        uninstalling = nil
    }

    @ViewBuilder private var content: some View {
        switch catalog {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t List Plugins", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        case .ready(let catalog):
            // A grouped form, like Settings: an inset List trapped in its outline code on these rows.
            let installed = catalog.installed.filter(matches)
            let installedIDs = Set(catalog.installed.map(\.id))
            let available = Array(catalog.available.filter { !installedIDs.contains($0.id) && matches($0) }.prefix(200))
            Form {
                Section("Installed") {
                    if installed.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        ForEach(installed) { installedRow($0) }
                    }
                }
                Section("Available") {
                    if available.isEmpty {
                        Text(search.isEmpty ? "None" : "No Matches").foregroundStyle(.secondary)
                    } else {
                        ForEach(available) { availableRow($0) }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The plugin's switch, titled by its name, with where it came from as the subtitle.
    private func installedRow(_ plugin: InstalledPlugin) -> some View {
        Group {
            if working == plugin.id {
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    installedLabel(plugin)
                }
            } else {
                Toggle(isOn: Binding(get: { plugin.enabled }, set: { on in
                    change(plugin.id) { try await $0.setPlugin(plugin, enabled: on, cwd: folder) }
                })) {
                    installedLabel(plugin)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .contextMenu { Button("Uninstall…") { uninstalling = plugin } }
    }

    @ViewBuilder private func installedLabel(_ plugin: InstalledPlugin) -> some View {
        Text(plugin.name)
        Text([plugin.marketplace, plugin.version.map { "v\($0)" }, plugin.scope.map(Self.scopeLabel)].compactMap { $0 }.joined(separator: " · "))
    }

    /// The plugin's name, what it does and how many have installed it, then Install.
    private func availableRow(_ plugin: AvailablePlugin) -> some View {
        LabeledContent {
            if working == plugin.id {
                ProgressView().controlSize(.small)
            } else {
                Menu("Install") {
                    Button("For Me") { install(plugin, .user) }
                    Button("For This Project") { install(plugin, .project) }.disabled(folder == nil)
                    Button("For This Project, Just Me") { install(plugin, .local) }.disabled(folder == nil)
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.small)
            }
        } label: {
            Text(plugin.name)
            Text(plugin.description).lineLimit(2)
            if let count = plugin.installCount {
                Text("\(count.formatted()) installs")
            }
        }
    }

    private func matches(_ plugin: InstalledPlugin) -> Bool {
        search.isEmpty || plugin.id.localizedCaseInsensitiveContains(search)
    }

    private func matches(_ plugin: AvailablePlugin) -> Bool {
        search.isEmpty || plugin.name.localizedCaseInsensitiveContains(search) || plugin.description.localizedCaseInsensitiveContains(search)
    }

    static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "user": "For Me"
        case "project": "For the Project"
        case "local": "For the Project, Just Me"
        default: scope.humanized
        }
    }

    private func install(_ plugin: AvailablePlugin, _ scope: PluginInstallParams.Scope) {
        change(plugin.id) { try await $0.installPlugin(plugin.id, scope: scope, cwd: folder) }
    }

    private func change(_ id: String, _ action: @escaping (HostConnection) async throws -> Void) {
        guard let connection else { return }
        working = id
        Task {
            do { try await action(connection) } catch { self.error = error.localizedDescription }
            await reload()
            working = nil
        }
    }

    private func reload() async {
        guard fetches, let connection else { return }
        do {
            catalog = .ready(try await connection.plugins(cwd: folder))
        } catch {
            catalog = .failed(error.localizedDescription)
        }
    }
}

/// Host ▸ Plugins….
struct ShowPluginsButton: View {
    let hostID: UUID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Plugins…") { openWindow(id: PluginsWindow.id, value: hostID) }
    }
}

#if DEBUG
#Preview("Plugins") {
    let app = AppModel.sample()
    let catalog = PluginCatalog(
        installed: [
            InstalledPlugin(["id": "swift-lsp@claude-plugins-official", "version": "1.0.0", "scope": "user", "enabled": true])!,
            InstalledPlugin(["id": "vercel@claude-plugins-official", "version": "0.50.0", "scope": "user", "enabled": false])!,
        ],
        available: [
            AvailablePlugin(["pluginId": "github@claude-plugins-official", "name": "github", "description": "Work with issues and pull requests.", "marketplaceName": "claude-plugins-official", "installCount": 48210])!,
            AvailablePlugin(["pluginId": "sentry@claude-plugins-official", "name": "sentry", "description": "Look up errors and their stack traces while debugging.", "marketplaceName": "claude-plugins-official", "installCount": 9120])!,
        ])
    PluginsWindow(app: app, hostID: app.hosts.first?.id, catalog: catalog)
        .frame(width: 640, height: 480)
}
#endif
