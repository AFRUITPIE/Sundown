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

/// Resolves the session settings in its own body rather than in `RootView`'s, so what they read —
/// the chat's model, effort and mode, the catalog — invalidates this toolbar item, not the shell.
struct ToolbarSessionControl<Control: View>: View {
    let app: AppModel
    let control: (SessionSettings) -> Control

    var body: some View { control(.current(app)) }
}

/// The chat's three settings as one toolbar item, so they share one glass capsule the way Xcode's
/// scheme and run destination do. Separate items would each get their own.
struct SessionMenus: View {
    let settings: SessionSettings

    var body: some View {
        HStack(spacing: 0) {
            ModelMenu(settings: settings)
            EffortMenu(settings: settings)
            PermissionsMenu(settings: settings)
        }
    }
}

/// The one control that shows a word: which model is answering is what people look for.
/// Fast Mode rides in its menu because it is a property of the model, not a fourth control.
struct ModelMenu: View {
    let settings: SessionSettings

    var body: some View {
        Menu {
            ModelPicker(settings: settings)
                .pickerStyle(.inline)
            Divider()
            FastModeToggle(settings: settings)
        } label: {
            ReservedWidthLabel(settings.modelLabel, systemImage: SessionSymbol.model,
                               widestOf: settings.models.concrete.map(\.shortName) + [settings.modelLabel])
        }
        // Toolbar items are icon-only by default; this is the one that has to say a name.
        .labelStyle(.titleAndIcon)
        .disabled(!settings.isEnabled)
        .help("Model: \(settings.modelLabel)")
        .accessibilityLabel("Model")
        .accessibilityValue(settings.modelLabel)
    }
}

/// Icon-only: the gauge's needle carries the value, the tooltip spells it out. A pull-down with a
/// checked list, like the model's, because a pop-up here would show its rows as bare gauges.
struct EffortMenu: View {
    let settings: SessionSettings

    private var levels: [EffortLevel] { settings.effortLevels }
    private var value: EffortLevel? { settings.effort.wrappedValue }

    var body: some View {
        Menu {
            EffortPicker(settings: settings)
                .pickerStyle(.inline)
        } label: {
            ReservedWidthLabel("Effort", systemImage: value.symbol(in: levels),
                               symbols: [SessionSymbol.automaticEffort] + levels.map { $0.symbol(in: levels) })
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

    private var mode: PermissionMode { settings.permissionMode.wrappedValue }

    var body: some View {
        Menu {
            PermissionsPicker(settings: settings)
                .pickerStyle(.inline)
        } label: {
            let label = ReservedWidthLabel(mode.label, systemImage: mode.symbol,
                                           symbols: PermissionMode.selectable.map(\.symbol))
            // Only the dangerous mode styles its label: an unconditional `.foregroundStyle` would
            // also paint over the disabled appearance.
            if mode.isDangerous {
                label.foregroundStyle(.red)
            } else {
                label
            }
        }
        .labelStyle(.iconOnly)
        .disabled(!settings.isEnabled)
        .help("Permissions: \(mode.longLabel)")
        .accessibilityLabel("Permissions")
        .accessibilityValue(mode.longLabel)
    }
}

// The menus' contents, shared with the Chat menu, where each picker is a submenu.

struct ModelPicker: View {
    let settings: SessionSettings

    var body: some View {
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
    }
}

struct FastModeToggle: View {
    let settings: SessionSettings

    var body: some View {
        Toggle("Fast Mode", systemImage: SessionSymbol.fastMode, isOn: settings.fastMode)
            .disabled(settings.fastModeUnavailable != nil)
            .help(settings.fastModeUnavailable ?? "The same model, with faster output")
    }
}

struct EffortPicker: View {
    let settings: SessionSettings

    var body: some View {
        let levels = settings.effortLevels
        Picker("Effort", selection: settings.effort) {
            Label("Automatic", systemImage: SessionSymbol.automaticEffort).tag(EffortLevel?.none)
            ForEach(levels, id: \.self) { level in
                Label(level.label, systemImage: level.symbol(in: levels)).tag(Optional(level))
            }
        }
    }
}

struct PermissionsPicker: View {
    let settings: SessionSettings

    var body: some View {
        Picker("Permissions", selection: settings.permissionMode) {
            ForEach(PermissionMode.selectable, id: \.self) { mode in
                Label(mode.longLabel, systemImage: mode.symbol).tag(mode)
            }
        }
    }
}

/// The Chat menu: the open chat's settings, or the New Chat draft's, for a hidden or customized
/// toolbar.
public struct ChatCommands: View {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        let settings = SessionSettings.current(app)
        Group {
            ModelPicker(settings: settings)
            FastModeToggle(settings: settings)
            EffortPicker(settings: settings)
            PermissionsPicker(settings: settings)
        }
        .disabled(!settings.isEnabled)
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

/// Declared the way `RootView` declares them, so a preview shows the real glass shape and spacing
/// rather than three bare menus.
private struct SessionControlsPreview: View {
    let settings: SessionSettings

    var body: some View {
        NavigationStack {
            Color.clear
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { SessionMenus(settings: settings) }
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

/// A preview can't open a menu, so the same pickers are laid out here to check the rows'
/// symbols and wording.
#Preview("Session menu contents") {
    let settings = previewSettings(thread: .sample(model: "sonnet", effort: .medium, fastModeState: .on))
    return Form {
        Section("Model") {
            ModelPicker(settings: settings).labelsHidden()
            FastModeToggle(settings: settings)
        }
        Section("Effort") { EffortPicker(settings: settings).labelsHidden() }
        Section("Permissions") { PermissionsPicker(settings: settings).labelsHidden() }
    }
    .pickerStyle(.inline)
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
