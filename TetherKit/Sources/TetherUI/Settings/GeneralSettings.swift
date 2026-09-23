import SwiftUI
import TetherKit
import TetherProtocol

/// What a new chat starts with, and how the window looks. Every row here is a pop-up or a
/// segmented control with the same words and symbols the toolbar uses for the same value.
struct GeneralSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("New Chats") {
                modelRow
                effortRow
                permissionsRow
            }
            Section("Appearance") {
                Picker("Transcript Width", selection: $app.transcriptWidth) {
                    ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Group Chats By", selection: $app.sidebarGrouping) {
                    ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: new-chat defaults

    /// The catalog of the host the window is on, falling back to this Mac's: the names are the
    /// CLI's, so any connected host can supply them.
    private var models: [ModelInfo] {
        let current = app.connection?.models ?? []
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
        Picker("Permissions", selection: permissionSelection) {
            ForEach(PermissionMode.selectable, id: \.self) { mode in
                Label(mode.longLabel, systemImage: mode.symbol).tag(mode)
            }
        }
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

#if DEBUG
#Preview("General") {
    GeneralSettings(app: .sample())
}

/// No host has answered yet, so the model row shows what is stored instead of an empty pop-up.
#Preview("General (no catalog)") {
    let app = AppModel.sample(connections: [.sampleDisconnected()])
    app.defaultModel = "claude-sonnet-5"
    app.defaultEffort = "high"
    return GeneralSettings(app: app)
}
#endif
