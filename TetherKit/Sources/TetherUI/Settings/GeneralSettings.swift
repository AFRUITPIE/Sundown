import SwiftUI
import TetherKit
import TetherProtocol

/// What a new chat starts with, how chats read and send, and what Claude may do. The session rows
/// use the same words and symbols the toolbar uses for the same value.
struct GeneralSettings: View {
    @Bindable var app: AppModel
    /// The editors on this Mac, looked up when the pane appears rather than in a body.
    @State private var editors: [InstalledEditor] = []

    var body: some View {
        Form {
            Section("New Chats") {
                modelRow
                effortRow
                permissionsRow
                Picker("Folder", selection: $app.appearance.newChatFolder) {
                    ForEach(Appearance.NewChatFolder.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Start in a New Worktree", isOn: $app.appearance.worktreeByDefault)
            }
            Section("Chats") {
                Picker("Send With", selection: $app.appearance.sendShortcut) {
                    ForEach(Appearance.SendShortcut.allCases) { Text($0.label).tag($0) }
                }
                Picker("Reading Width", selection: $app.transcriptWidth) {
                    ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Text Size", selection: $app.textScale) {
                    ForEach(TextScale.steps, id: \.self) { Text(TextScale.label($0)).tag($0) }
                }
                Toggle("Wrap Long Lines in Code", isOn: $app.appearance.wrapCode)
                editorRow
            }
            Section {
                Toggle("Offer Bypass Permissions", isOn: $app.appearance.offerBypass)
                Toggle("Let Claude Read Your Other Chats", isOn: $app.appearance.sessionTools)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Reading other chats takes effect in chats started or reopened after it’s turned on.")
            }
        }
        .formStyle(.grouped)
        .task { editors = InstalledEditor.all() }
    }

    /// Default App, then the editors that are installed. One chosen before it was removed stays
    /// listed, so the pop-up still has a row for its value; Open then uses the default app.
    private var editorRow: some View {
        Picker("Open Files With", selection: $app.appearance.openFilesWith) {
            Text(Appearance.FileEditor.defaultApp.label).tag(Appearance.FileEditor.defaultApp)
            Divider()
            ForEach(editors) { installed in
                Label { Text(installed.editor.label) } icon: { Image(nsImage: installed.icon) }
                    .tag(installed.editor)
            }
            let chosen = app.appearance.openFilesWith
            if chosen != .defaultApp, !editors.contains(where: { $0.editor == chosen }) {
                Text(chosen.label).tag(chosen)
            }
        }
    }

    // MARK: new-chat defaults

    /// The catalog of the most recently used window's host, falling back to this Mac's: the names
    /// are the CLI's, so any connected host can supply them.
    private var models: [ModelInfo] {
        let current = app.connection(app.lastHostID)?.models ?? []
        return current.isEmpty ? (app.connection(HostConfig.local.id)?.models ?? []) : current
    }

    /// With no catalog there is nothing to choose from, so the stored value is shown as it is
    /// rather than as an empty pop-up.
    @ViewBuilder private var modelRow: some View {
        if models.isEmpty {
            LabeledContent("Model") {
                Text(app.defaultModel ?? "Not Connected")
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
        } else {
            Picker("Model", selection: modelSelection) {
                ForEach(models.concrete, id: \.value) { Text($0.shortName).tag(Optional($0.value)) }
                // A Bedrock or otherwise unlisted id the user already stored stays selectable.
                if let model = app.defaultModel,
                   !models.contains(where: { $0.value == model || $0.resolvedModel == model }) {
                    Text(model).tag(Optional(model))
                }
            }
        }
    }

    private var effortRow: some View {
        Picker("Effort", selection: effortSelection) {
            Label("Automatic", systemImage: SessionSymbol.automaticEffort).tag(EffortLevel?.none)
            ForEach(effortLevels, id: \.self) { level in
                Label(level.label, systemImage: level.symbol(in: effortLevels)).tag(Optional(level))
            }
        }
    }

    private var permissionsRow: some View {
        PermissionModeFormPicker(selection: permissionSelection,
                                 modes: PermissionMode.offered(bypass: app.appearance.offerBypass,
                                                               current: PermissionMode(rawValue: app.defaultPermissionMode)))
    }

    /// The levels the default model offers, so the gauges mean the same thing they do in the
    /// toolbar; every level while no catalog says otherwise.
    private var effortLevels: [EffortLevel] {
        let value = models.concreteValue(for: app.defaultModel)
        return models.concrete.first { $0.value == value }?.supportedEffortLevels ?? EffortLevel.allCases
    }

    /// Always a named model: with nothing stored, the one the catalog would pick.
    private var modelSelection: Binding<String?> {
        Binding(get: { models.concreteValue(for: app.defaultModel) },
                set: { app.defaultModel = $0 })
    }

    private var effortSelection: Binding<EffortLevel?> {
        Binding(get: { app.defaultEffort.map(EffortLevel.init(rawValue:)) },
                set: { app.defaultEffort = $0?.rawValue })
    }

    private var permissionSelection: Binding<PermissionMode> {
        Binding(get: { PermissionMode(rawValue: app.defaultPermissionMode) },
                set: { app.defaultPermissionMode = $0.rawValue })
    }
}

/// Permissions as a Settings row: a pop-up of the modes, with what the chosen one does under the
/// row's title. A pop-up's rows can't show a subtitle the way the toolbar menu's items do, so the
/// line goes where a grouped form puts a row's description. Settings and scheduled tasks share it.
struct PermissionModeFormPicker: View {
    let selection: Binding<PermissionMode>
    let modes: [PermissionMode]

    var body: some View {
        Picker(selection: selection) {
            ForEach(modes, id: \.self) { mode in
                Label(mode.longLabel, systemImage: mode.symbol).tag(mode)
            }
        } label: {
            Text("Permissions")
            if let summary = selection.wrappedValue.summary { Text(summary) }
        }
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettings(app: .sample())
        .frame(width: 560, height: 780)
}

/// Files open in an editor, and new chats start in Plan Mode, whose line reads under the row. The
/// editors listed are the ones installed on the Mac rendering the preview.
#Preview("General (editor, plan mode)") {
    let app = AppModel.sample()
    app.appearance.openFilesWith = .xcode
    app.defaultPermissionMode = PermissionMode.plan.rawValue
    return GeneralSettings(app: app)
        .frame(width: 560, height: 780)
}

/// No host has answered yet, so the model row shows what is stored instead of an empty pop-up.
#Preview("General (no catalog)") {
    let app = AppModel.sample(connections: [.sampleDisconnected()])
    app.defaultModel = "claude-sonnet-5"
    app.defaultEffort = "high"
    return GeneralSettings(app: app)
}
#endif
