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
    /// The effort Claude Code sends when none is chosen: the model's own default, or the host's
    /// `effortLevel`. Nil when it isn't known.
    let defaultEffort: EffortLevel?
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
        // With none chosen, the effort in use is the default.
        defaultEffort = thread.effort == nil ? thread.info?.appliedEffort : nil
        isEnabled = true
    }

    /// The New Chat draft, carried into `startThread`. Without a connection there is no catalog
    /// and nothing to set, so the menus stay on screen disabled.
    init(draft window: WindowModel, connection: HostConnection?) {
        // Resolved against the catalog here too: it usually lands after `newChat()` seeded the draft.
        model = Binding(get: { connection?.models.concreteValue(for: window.draftModel) ?? window.draftModel },
                        set: { window.draftModel = $0 })
        effort = Binding(get: { window.draftEffort }, set: { window.draftEffort = $0 })
        // Until one is chosen, the mode the host's Claude Code starts a chat in.
        permissionMode = Binding(get: { window.draftPermissionMode ?? window.draftDefaults?.permissionMode ?? .default },
                                 set: { window.draftPermissionMode = $0 })
        fastMode = Binding(get: { window.draftFastMode }, set: { window.draftFastMode = $0 })
        models = connection?.models ?? []
        fastModeDisabledReason = nil
        defaultEffort = window.draftDefaults?.effort
        isEnabled = connection != nil
    }

    /// The one place that decides which of the two the toolbar is driving.
    static func current(_ window: WindowModel) -> SessionSettings {
        let settings = if let thread = window.selectedThread, let connection = window.connection {
            SessionSettings(thread: thread, connection: connection)
        } else {
            SessionSettings(draft: window, connection: window.connection)
        }
        return settings.offering(bypass: window.app.appearance.offerBypass)
    }

    /// Settings ▸ General ▸ Offer Bypass Permissions.
    var offersBypass = false

    func offering(bypass: Bool) -> SessionSettings {
        var settings = self
        settings.offersBypass = bypass
        return settings
    }

    var offeredModes: [PermissionMode] {
        PermissionMode.offered(bypass: offersBypass, current: permissionMode.wrappedValue)
    }

    /// Auto needs a model that supports it; one that says it doesn't can't be put in it.
    var autoModeUnavailable: Bool { currentModel?.supportsAutoMode == false }

    /// The catalog entry behind the current selection — the catalog's own default while the chat
    /// hasn't reported one, and nil for a model the CLI doesn't list.
    var currentModel: ModelInfo? {
        let value = models.concreteValue(for: model.wrappedValue)
        return models.concrete.first { $0.value == value }
    }

    /// What the model control shows: "Opus 5", or the raw id of an unlisted (Bedrock) model.
    var modelLabel: String { currentModel?.displayName ?? model.wrappedValue ?? "Model" }

    /// The levels this model offers; the gauge's needle is spread across them.
    var effortLevels: [EffortLevel] { currentModel?.supportedEffortLevels ?? EffortLevel.allCases }

    /// A model Claude Code lists without any effort levels takes none, so there's nothing to set.
    var effortUnavailable: Bool {
        guard let model = currentModel else { return false }
        return model.supportsEffort != true && (model.supportedEffortLevels ?? []).isEmpty
    }

    /// The effort in use: the one chosen, else Claude Code's default for the model.
    var effectiveEffort: EffortLevel? { effort.wrappedValue ?? defaultEffort }

    /// What the effort control says: the level in use, or why there's none.
    var effortLabel: String {
        if effortUnavailable { return "None" }
        return effectiveEffort?.label ?? "Default"
    }

    /// Why Fast Mode can't be switched on, or nil when it can.
    var fastModeUnavailable: String? {
        guard currentModel?.supportsFastMode == true else { return "\(modelLabel) doesn't support Fast Mode" }
        return fastModeDisabledReason
    }
}

/// Resolves the session settings in its own body rather than in `RootView`'s, so what they read —
/// the chat's model, effort and mode, the catalog — invalidates this toolbar item, not the shell.
struct ToolbarSessionControl<Control: View>: View {
    let window: WindowModel
    let control: (SessionSettings) -> Control

    var body: some View { control(.current(window)) }
}

/// The chat's three settings as one toolbar item, a control group, so they share one glass capsule
/// the way Xcode's scheme and run destination do, and the » menu calls them Session.
struct SessionMenus: View {
    let settings: SessionSettings

    var body: some View {
        ControlGroup {
            ModelMenu(settings: settings)
            EffortMenu(settings: settings)
            PermissionsMenu(settings: settings)
        } label: {
            Label("Session", systemImage: SessionSymbol.model)
        }
        // One capsule, as Safari's back and forward share one (the default style gave each menu its
        // own); the chevrons still say each is a menu.
        .controlGroupStyle(.navigation)
        .menuIndicator(.visible)
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
            Label(settings.modelLabel, systemImage: SessionSymbol.model)
                // Toolbar items are icon-only by default; this is the one that has to say a name.
                // On the label, not the menu, which would pass it on to the menu's items.
                .labelStyle(.titleAndIcon)
        }
        .disabled(!settings.isEnabled)
        .help("Model")
        // The choice in the label: in the toolbar's control group a value never reaches VoiceOver.
        .accessibilityLabel("Model, \(settings.modelLabel)")
    }
}

/// A gauge whose needle carries the value, the tooltip spelling it out, shown as the toolbar's
/// display mode says (icon only by default). A pull-down with a checked list, like the model's,
/// because a pop-up here would show its rows as bare gauges.
struct EffortMenu: View {
    let settings: SessionSettings

    private var levels: [EffortLevel] { settings.effortLevels }

    var body: some View {
        Menu {
            EffortPicker(settings: settings)
                .pickerStyle(.inline)
        } label: {
            // The needle says the level in use, chosen or Claude Code's default.
            Label("Effort", systemImage: settings.effectiveEffort.symbol(in: levels))
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(!settings.isEnabled || settings.effortUnavailable)
        .help(settings.effortUnavailable ? "\(settings.modelLabel) doesn’t take an effort level" : "Effort, \(settings.effortLabel)")
        // The choice in the label: in the toolbar's control group a value never reaches VoiceOver.
        .accessibilityLabel("Effort, \(settings.effortLabel)")
    }
}

/// The mode's symbol, and the only control that ever shows colour: bypass means Claude stops asking.
struct PermissionsMenu: View {
    let settings: SessionSettings

    private var mode: PermissionMode { settings.permissionMode.wrappedValue }

    var body: some View {
        Menu {
            Section("Permissions") { PermissionModeItems(settings: settings) }
        } label: {
            let label = Label(mode.label, systemImage: mode.symbol)
                .contentTransition(.symbolEffect(.replace))
            // Only the dangerous mode styles its label: an unconditional `.foregroundStyle` would
            // also paint over the disabled appearance.
            if mode.isDangerous {
                label.foregroundStyle(.red)
            } else {
                label
            }
        }
        .disabled(!settings.isEnabled)
        .help("Permissions")
        // The choice in the label: in the toolbar's control group a value never reaches VoiceOver.
        .accessibilityLabel("Permissions, \(mode.longLabel)")
    }
}

// The menus' contents, shared with the Chat menu, where each picker is a submenu.

struct ModelPicker: View {
    let settings: SessionSettings

    var body: some View {
        Picker("Model", selection: settings.model) {
            ForEach(settings.models.concrete, id: \.value) { model in
                Text(model.displayName).tag(Optional(model.value))
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
        // What it does, or why it can't be switched on, as the item's subtitle.
        Toggle(isOn: settings.fastMode) {
            Label("Fast Mode", systemImage: SessionSymbol.fastMode)
            Text(settings.fastModeUnavailable ?? "The same model, with faster output")
        }
        .disabled(settings.fastModeUnavailable != nil)
    }
}

struct EffortPicker: View {
    let settings: SessionSettings

    var body: some View {
        let levels = settings.effortLevels
        Picker("Effort", selection: settings.effort) {
            // Claude Code's own level for the model, as its /effort offers it.
            Label(settings.defaultEffort.map { "Default (\($0.label))" } ?? "Default",
                  systemImage: SessionSymbol.automaticEffort).tag(EffortLevel?.none)
            ForEach(levels, id: \.self) { level in
                Label(level.label, systemImage: level.symbol(in: levels)).tag(Optional(level))
            }
        }
    }
}

/// The modes as menu items, each with a line under its name saying what it does. Toggles bound to
/// the selection, not a Picker: a Picker's rows become menu items without their second `Text`,
/// where a Toggle's becomes the item's subtitle, and a Toggle is checked like a picker row
/// (`PermissionMenuItemsTests` reads the menu SwiftUI builds). Choosing the checked mode again
/// leaves it chosen.
struct PermissionModeItems: View {
    let settings: SessionSettings

    var body: some View {
        let selection = settings.permissionMode
        ForEach(settings.offeredModes, id: \.self) { mode in
            Toggle(isOn: Binding(get: { selection.wrappedValue == mode },
                                 set: { if $0 { selection.wrappedValue = mode } })) {
                Label(mode.longLabel, systemImage: mode.symbol)
                if let summary = mode.summary { Text(summary) }
            }
            .disabled(mode == .auto && settings.autoModeUnavailable)
        }
    }
}

/// The Chat menu, for the frontmost window: the open chat's settings, or the New Chat draft's,
/// for a narrow window's » menu, then what can be done to the chat itself. With no window
/// open every item is still listed, dimmed.
public struct ChatCommands: View {
    @FocusedValue(\.window) private var window

    public init() {}

    public var body: some View {
        if let window {
            let settings = SessionSettings.current(window)
            Group {
                ModelPicker(settings: settings)
                FastModeToggle(settings: settings)
                EffortPicker(settings: settings)
                    .disabled(settings.effortUnavailable)
                Menu("Permissions") { PermissionModeItems(settings: settings) }
            }
            .disabled(!settings.isEnabled)
            Divider()
            // Not ⌘;, which is Edit ▸ Spelling and Grammar ▸ Check Document Now.
            Button("Ask a Side Question…") { window.sideQuestion = window.selectedThread }
                .keyboardShortcut(";", modifiers: [.command, .option])
                .disabled(window.selectedThread == nil)
            // Here, not on the Stop button, which is Send again once there's text in the field.
            Button("Stop") {
                if let thread = window.selectedThread, let connection = window.connection {
                    Task { await connection.interrupt(thread) }
                } else {
                    window.stopStarting()
                }
            }
            .keyboardShortcut(".")
            // A chat New Chat is starting can be stopped too: it's interrupted once it has started.
            .disabled(window.selectedThread?.isRunning != true && window.starting == nil)
            Divider()
            // ⌥⌘, not ⌘ or ⌃⌘: a text field keeps ⌘↑ and ⌘↓ (start and end of the text) and ⌃⌘↓
            // (writing direction); it has nothing on ⌥⌘↑ or ⌥⌘↓, so these work from the composer.
            Button("Previous Prompt") { window.prompts.go(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(window.selectedThread == nil)
            Button("Next Prompt") { window.prompts.go(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(window.selectedThread == nil)
            Divider()
            // Not ⌃⇥, which is Window ▸ Show Next Tab: windows gather into tabs, as any window group's do.
            Button("Next Chat") { window.showAdjacentChat(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(window.adjacentChat(1) == nil)
            Button("Previous Chat") { window.showAdjacentChat(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(window.adjacentChat(-1) == nil)
            Divider()
            ChatActionItems(window: window, thread: window.selectedThread)
        } else {
            Group {
                ForEach(["Model", "Fast Mode", "Effort", "Permissions"], id: \.self) { Button($0) {} }
                Divider()
                Button("Ask a Side Question…") {}
                Button("Stop") {}
                Divider()
                ForEach(["Previous Prompt", "Next Prompt"], id: \.self) { Button($0) {} }
                Divider()
                ForEach(["Next Chat", "Previous Chat"], id: \.self) { Button($0) {} }
                Divider()
                ForEach(["Open in New Window", "Pin", "Rename…", "Duplicate", "Show in Finder", "Archive", "Delete…"], id: \.self) { Button($0) {} }
            }
            .disabled(true)
        }
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
    let window = WindowModel.sample(.sample(connections: [connection]))
    return SessionSettings(draft: window, connection: connected ? connection : nil)
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

/// A Bedrock host with a `modelPicker`: the model reads as the label written there.
#Preview("SessionControls (Bedrock model picker)") {
    SessionControlsPreview(settings: previewSettings(
        thread: .sample(model: "us.anthropic.claude-sonnet-4-6", effort: .medium), connection: .sampleBedrockPicker()))
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
        Section("Permissions") { PermissionModeItems(settings: settings) }
    }
    .pickerStyle(.inline)
    // Checked like the menu's items, rather than switches.
    .toggleStyle(.checkbox)
    .formStyle(.grouped)
    .frame(width: 380, height: 800)
}

/// Every mode's name and the line under it, Bypass Permissions offered, as the permissions menu
/// lists them.
#Preview("Permissions menu contents") {
    var settings = previewSettings(thread: .sample(model: "sonnet", effort: .medium, permissionMode: .acceptEdits))
    settings.offersBypass = true
    return Form {
        Section("Permissions") { PermissionModeItems(settings: settings) }
    }
    .toggleStyle(.checkbox)
    .formStyle(.grouped)
    .frame(width: 400, height: 440)
}

/// The needle spread for every catalog shape, so a model with four levels reads as sensibly as
/// one with three.
#Preview("Effort gauges") {
    let catalogs: [[EffortLevel]] = [[.low, .high], [.low, .medium, .high], [.low, .medium, .high, .max], EffortLevel.allCases]
    return VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(catalogs.enumerated()), id: \.offset) { _, levels in
            HStack(spacing: 14) {
                Label("Default", systemImage: SessionSymbol.automaticEffort)
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
