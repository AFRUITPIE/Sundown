import SwiftUI
import TetherKit
import TetherProtocol

/// What the three session menus read and write, resolved in one place. A live chat writes through
/// its connection (optimistic state is already `ThreadModel.pendingSettings`), the New Chat screen
/// writes to the app's draft, and with no connection the same menus are disabled, never removed.
@MainActor
struct SessionSettings {
    let model: Binding<String?>
    let effort: Binding<EffortLevel?>
    let permissionMode: Binding<PermissionMode>
    let fastMode: Binding<Bool>
    let models: [ModelInfo]
    let isEnabled: Bool
    /// The daemon's own reason fast mode is off limits right now (rate limit, cooldown, …).
    private let fastModeDisabledReason: String?

    /// A live chat: every setter goes to the daemon, every getter reads the thread.
    init(thread: ThreadModel, connection: HostConnection) {
        model = Binding(get: { connection.models.concreteValue(for: thread.model) },
                        set: { value in Task { await connection.setModel(thread, value) } })
        effort = Binding(get: { thread.effort },
                         set: { value in Task { await connection.setEffort(thread, value) } })
        permissionMode = Binding(get: { thread.permissionMode ?? .default },
                                 set: { value in Task { await connection.setPermissionMode(thread, value) } })
        fastMode = Binding(get: { thread.fastMode },
                           set: { on in Task { await connection.setFastMode(thread, on) } })
        models = connection.models
        fastModeDisabledReason = thread.info?.fastModeDisabledReason
        isEnabled = true
    }

    /// The New Chat draft, carried into `startThread`. Without a connection there is no catalog
    /// and nothing to set, so the menus stay on screen disabled.
    init(draft app: AppModel, connection: HostConnection?) {
        // Resolved against the catalog here too: it usually lands after `newChat()` seeded the draft.
        model = Binding(get: { connection?.models.concreteValue(for: app.draftModel ?? app.defaultModel) ?? app.draftModel },
                        set: { app.draftModel = $0 })
        effort = Binding(get: { app.draftEffort }, set: { app.draftEffort = $0 })
        permissionMode = Binding(get: { app.draftPermissionMode }, set: { app.draftPermissionMode = $0 })
        fastMode = Binding(get: { app.draftFastMode }, set: { app.draftFastMode = $0 })
        models = connection?.models ?? []
        fastModeDisabledReason = nil
        isEnabled = connection != nil
    }

    /// The one place that decides which of the two the toolbar is driving.
    static func current(_ app: AppModel) -> SessionSettings {
        if let thread = app.selectedThread, let connection = app.connection {
            return SessionSettings(thread: thread, connection: connection)
        }
        return SessionSettings(draft: app, connection: app.connection)
    }

    /// The catalog entry behind the current selection — the catalog's own default while the chat
    /// hasn't reported one, and nil for a model the CLI doesn't list.
    var currentModel: ModelInfo? {
        let value = models.concreteValue(for: model.wrappedValue)
        return models.concrete.first { $0.value == value }
    }

    /// What the model control shows: "Opus 5", or the raw id of an unlisted (Bedrock) model.
    var modelLabel: String { currentModel?.shortName ?? model.wrappedValue ?? "Model" }

    /// The levels this model offers; the gauge's needle is spread across them.
    var effortLevels: [EffortLevel] { currentModel?.supportedEffortLevels ?? EffortLevel.allCases }

    /// Why Fast Mode can't be switched on, or nil when it can.
    var fastModeUnavailable: String? {
        guard currentModel?.supportsFastMode == true else { return "\(modelLabel) doesn't support Fast Mode" }
        return fastModeDisabledReason
    }
}

/// The one control that shows a word: which model is answering is what people look for.
/// Fast Mode rides in its menu because it is a property of the model, not a fourth control.
struct ModelMenu: View {
    let settings: SessionSettings

    var body: some View {
        Menu {
            Picker("Model", selection: settings.model) {
                ForEach(settings.models.concrete, id: \.value) { model in
                    Text(model.shortName).tag(Optional(model.value))
                }
                // A custom or Bedrock id the CLI doesn't list stays selectable.
                if let id = settings.model.wrappedValue,
                   !settings.models.contains(where: { $0.value == id || $0.resolvedModel == id }) {
                    Text(id).tag(Optional(id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Fast Mode", systemImage: SessionSymbol.fastMode, isOn: settings.fastMode)
                .disabled(settings.fastModeUnavailable != nil)
                .help(settings.fastModeUnavailable ?? "Answer faster, with less reasoning")
        } label: {
            Label(settings.modelLabel, systemImage: SessionSymbol.model)
        }
        // Toolbar items are icon-only by default; this is the one that has to say a name.
        .labelStyle(.titleAndIcon)
        .disabled(!settings.isEnabled)
        .help("Model: \(settings.modelLabel)")
        .accessibilityLabel("Model")
        .accessibilityValue(settings.modelLabel)
    }
}

/// Icon-only: the gauge's needle carries the value, the tooltip spells it out.
struct EffortMenu: View {
    let settings: SessionSettings

    private var levels: [EffortLevel] { settings.effortLevels }
    private var value: EffortLevel? { settings.effort.wrappedValue }

    var body: some View {
        Menu {
            Picker("Effort", selection: settings.effort) {
                Label("Automatic", systemImage: SessionSymbol.automaticEffort).tag(EffortLevel?.none)
                ForEach(levels, id: \.self) { level in
                    Label(level.label, systemImage: level.symbol(in: levels)).tag(Optional(level))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Effort", systemImage: value.symbol(in: levels))
        }
        .labelStyle(.iconOnly)
        .disabled(!settings.isEnabled)
        .help("Effort: \(value.label)")
        .accessibilityLabel("Effort")
        .accessibilityValue(value.label)
    }
}

/// Icon-only, and the only control that ever shows colour: bypass means Claude stops asking.
struct PermissionsMenu: View {
    let settings: SessionSettings

    /// Ordered as they escalate, with the dangerous one last.
    private let modes: [PermissionMode] = [.default, .acceptEdits, .plan, .auto, .dontAsk, .bypassPermissions]
    private var mode: PermissionMode { settings.permissionMode.wrappedValue }

    var body: some View {
        Menu {
            Picker("Permissions", selection: settings.permissionMode) {
                ForEach(modes, id: \.self) { mode in
                    Label(mode.longLabel, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // Only the dangerous mode styles its label: an unconditional `.foregroundStyle` would
            // also paint over the disabled appearance.
            if mode.isDangerous {
                Label(mode.label, systemImage: mode.symbol).foregroundStyle(.red)
            } else {
                Label(mode.label, systemImage: mode.symbol)
            }
        }
        .labelStyle(.iconOnly)
        .disabled(!settings.isEnabled)
        .help("Permissions: \(mode.longLabel)")
        .accessibilityLabel("Permissions")
        .accessibilityValue(mode.longLabel)
    }
}

#if DEBUG
// #Preview bodies are result-builder closures, so each case is built here. The models these
// bindings capture are kept alive by the closures themselves.
@MainActor
private func previewSettings(thread: ThreadModel, connection: HostConnection = .sample()) -> SessionSettings {
    SessionSettings(thread: thread, connection: connection)
}

@MainActor
private func previewDraftSettings(connected: Bool = true) -> SessionSettings {
    let connection: HostConnection = connected ? .sample() : .sampleDisconnected()
    let app = AppModel.sample(connections: [connection])
    return SessionSettings(draft: app, connection: connected ? connection : nil)
}

/// The three declared the way `RootView` declares them — one toolbar item each — so a preview
/// shows the real glass shapes and spacing rather than three bare menus.
private struct SessionControlsPreview: View {
    let settings: SessionSettings

    var body: some View {
        NavigationStack {
            Color.clear
                .toolbar {
                    ToolbarItem(placement: .principal) { ModelMenu(settings: settings) }
                    ToolbarItem(placement: .principal) { EffortMenu(settings: settings) }
                    ToolbarItem(placement: .principal) { PermissionsMenu(settings: settings) }
                }
        }
        // Wide enough that the preview window's own title never pushes a control into the `»` overflow.
        .frame(width: 620, height: 120)
    }
}

#Preview("SessionControls (chat)") {
    // Sonnet supports fast mode, and this chat has it on.
    SessionControlsPreview(settings: previewSettings(
        thread: .sample(model: "sonnet", effort: .medium, fastModeState: .on)))
}

#Preview("SessionControls (new chat)") {
    SessionControlsPreview(settings: previewDraftSettings())
}

#Preview("SessionControls (no connection)") {
    SessionControlsPreview(settings: previewDraftSettings(connected: false))
}

#Preview("SessionControls (bypass permissions)") {
    SessionControlsPreview(settings: previewSettings(
        thread: .sample(model: "opus", effort: .max, permissionMode: .bypassPermissions)))
}

#Preview("SessionControls (no fast mode)") {
    // Opus has no fast mode, so the toggle in the model menu is disabled with a reason.
    SessionControlsPreview(settings: previewSettings(thread: .sample(model: "opus", effort: nil)))
}

/// A preview can't open a menu, so the same inline pickers are laid out here to check the rows'
/// symbols and wording.
#Preview("Session menu contents") {
    let settings = previewSettings(thread: .sample(model: "sonnet", effort: .medium, fastModeState: .on))
    return Form {
        Section("Model") {
            Picker("Model", selection: settings.model) {
                ForEach(settings.models.concrete, id: \.value) { Text($0.shortName).tag(Optional($0.value)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Toggle("Fast Mode", systemImage: SessionSymbol.fastMode, isOn: settings.fastMode)
        }
        Section("Effort") {
            Picker("Effort", selection: settings.effort) {
                Label("Automatic", systemImage: SessionSymbol.automaticEffort).tag(EffortLevel?.none)
                ForEach(settings.effortLevels, id: \.self) { level in
                    Label(level.label, systemImage: level.symbol(in: settings.effortLevels)).tag(Optional(level))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Permissions") {
            Picker("Permissions", selection: settings.permissionMode) {
                ForEach([PermissionMode.default, .acceptEdits, .plan, .auto, .dontAsk, .bypassPermissions], id: \.self) { mode in
                    Label(mode.longLabel, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
    .formStyle(.grouped)
    .frame(width: 340, height: 760)
}

/// The needle spread for every catalog shape, so a model with four levels reads as sensibly as
/// one with three.
#Preview("Effort gauges") {
    let catalogs: [[EffortLevel]] = [[.low, .high], [.low, .medium, .high], [.low, .medium, .high, .max], EffortLevel.allCases]
    return VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(catalogs.enumerated()), id: \.offset) { _, levels in
            HStack(spacing: 14) {
                Label("Automatic", systemImage: SessionSymbol.automaticEffort)
                ForEach(levels, id: \.self) { level in
                    Label(level.label, systemImage: level.symbol(in: levels))
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.callout)
        }
    }
    .padding(20)
}
#endif
