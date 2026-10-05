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

/// Model and effort as one toolbar button, the model's name, opening a
/// popover with the models, Fast Mode and the effort levels together.
struct ModelEffortButton: View {
    let settings: SessionSettings
    /// The sparkle alone, for Customize Toolbar's icon-only version: unlike the name, it can share a
    /// glass capsule with the buttons beside it.
    var iconOnly = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            // Titled "Model", which Customize Toolbar and the » menu read; drawn as the model's name
            // unless it's the icon-only version.
            if iconOnly {
                Label("Model", systemImage: SessionSymbol.model)
            } else {
                Label("Model", systemImage: SessionSymbol.model)
                    .labelStyle(ValueLabelStyle(value: settings.modelLabel))
            }
        }
        .disabled(!settings.isEnabled)
        .help("Model and Effort")
        .accessibilityLabel("Model, \(settings.modelLabel), Effort, \(settings.effortLabel)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelEffortForm(settings: settings)
                .popoverSize(width: 300)
        }
    }
}

/// Draws a label as a value ("Opus 5.5") while its title, which Customize Toolbar and the » menu
/// read, stays the control's name ("Model").
struct ValueLabelStyle: LabelStyle {
    let value: String
    func makeBody(configuration: Configuration) -> some View { Text(value) }
}

/// The popover's contents: the models as rows, each with Claude Code's line about it and a
/// checkmark on the chosen one, Fast Mode under them, then the effort as a stepped slider.
struct ModelEffortForm: View {
    let settings: SessionSettings

    var body: some View {
        Form {
            Section("Model") {
                ModelRows(settings: settings)
            }
            Section {
                FastModeToggle(settings: settings)
            }
            Section("Effort") {
                EffortSlider(settings: settings)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// The models as a selectable list, as Control Center lists Wi-Fi networks: the name, its
/// description under it, a checkmark trailing. The whole row is the button.
struct ModelRows: View {
    let settings: SessionSettings

    private func row(_ model: ModelInfo, selected: String?) -> some View {
        ChoiceRow(title: model.displayName, detail: model.description,
                 isSelected: model.value == selected) {
            settings.model.wrappedValue = model.value
        }
    }

    var body: some View {
        let selected = settings.models.concreteValue(for: settings.model.wrappedValue)
        ForEach(settings.models.concrete, id: \.value) { model in
            row(model, selected: selected)
        }
        // A custom or Bedrock id the CLI doesn't list stays selectable.
        if let id = settings.model.wrappedValue,
           !settings.models.contains(where: { $0.value == id || $0.resolvedModel == id }) {
            ChoiceRow(title: id, detail: "", isSelected: true) { settings.model.wrappedValue = id }
        }
    }
}

/// One choice in a popover's list: its name, a line saying what it is, a checkmark when chosen.
private struct ChoiceRow: View {
    let title: String
    var symbol: String? = nil
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The checkmark centered on the row; the symbol on the title's line.
            HStack {
                HStack(alignment: .firstTextBaseline) {
                    if let symbol {
                        Image(systemName: symbol).frame(width: 20)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The effort levels the model offers as stops on a slider. The stop on Claude Code's own level
/// for the model is "unset": moving onto it clears the effort, any other stop sets it.
struct EffortSlider: View {
    let settings: SessionSettings
    /// The default seen while no effort was chosen: once one is, a live chat no longer reports it.
    @State private var seenDefault: EffortLevel?

    private var defaultLevel: EffortLevel? { settings.defaultEffort ?? seenDefault }

    private func name(_ level: EffortLevel) -> String {
        level == defaultLevel ? "\(level.label) (Default)" : level.label
    }

    var body: some View {
        let levels = settings.effortLevels
        let current = settings.effectiveEffort ?? defaultLevel
        let title: String = current.map { name($0) } ?? "Default"
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            if levels.count > 1 {
                EffortStops(levels: levels, index: current.flatMap { levels.firstIndex(of: $0) } ?? 0,
                            valueName: title) { level in
                    settings.effort.wrappedValue = level == defaultLevel ? nil : level
                }
            }
        }
        .disabled(settings.effortUnavailable)
        .onAppear { seenDefault = settings.defaultEffort ?? seenDefault }
        .onChange(of: settings.defaultEffort) { _, new in seenDefault = new ?? seenDefault }
    }
}

/// The slider itself: one tick per level, the first and last named at its ends.
private struct EffortStops: View {
    let levels: [EffortLevel]
    let index: Int
    let valueName: String
    let choose: (EffortLevel) -> Void

    var body: some View {
        let last = levels.count - 1
        let position = Binding<Double>(
            get: { Double(index) },
            set: { choose(levels[min(max(Int($0.rounded()), 0), last)]) })
        let stops: [Double] = (0...last).map { Double($0) }
        Slider(value: position, in: 0...Double(last)) {
            Text("Effort")
        } minimumValueLabel: {
            Text(levels[0].label).font(.caption)
        } maximumValueLabel: {
            Text(levels[last].label).font(.caption)
        } ticks: {
            SliderTickContentForEach(stops, id: \.self) { SliderTick($0) }
        }
        .labelsHidden()
        .accessibilityValue(valueName)
    }
}

/// The mode's symbol, and the only control that ever shows colour: bypass means Claude stops asking.
/// A button opening a popover of the modes, not a menu: a toolbar menu never shares a glass capsule
/// with the buttons beside it.
struct PermissionsButton: View {
    let settings: SessionSettings
    @State private var isPresented = false

    private var mode: PermissionMode { settings.permissionMode.wrappedValue }

    var body: some View {
        Button { isPresented.toggle() } label: {
            // Titled "Permissions" for Customize Toolbar and the » menu; the toolbar shows the symbol.
            let label = Label("Permissions", systemImage: mode.symbol)
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
        .help("Permissions, \(mode.longLabel)")
        .accessibilityLabel("Permissions, \(mode.longLabel)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PermissionsForm(settings: settings)
                .popoverSize(width: 320)
        }
    }
}

/// The popover's modes, each with the line saying what it does.
struct PermissionsForm: View {
    let settings: SessionSettings

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(settings.offeredModes, id: \.self) { mode in
                    ChoiceRow(title: mode.longLabel, symbol: mode.symbol, detail: mode.summary ?? "",
                              isSelected: mode == settings.permissionMode.wrappedValue) {
                        settings.permissionMode.wrappedValue = mode
                    }
                    .disabled(mode == .auto && settings.autoModeUnavailable)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                    ToolbarItem(placement: .primaryAction) { ModelEffortButton(settings: settings) }
                    ToolbarItem(placement: .primaryAction) { PermissionsButton(settings: settings) }
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
    // Opus has no fast mode, so the toggle in the popover is disabled with a reason.
    SessionControlsPreview(settings: previewSettings(thread: .sample(model: "opus", effort: nil)))
}

/// A Bedrock host with a `modelPicker`: the model reads as the label written there.
#Preview("SessionControls (Bedrock model picker)") {
    SessionControlsPreview(settings: previewSettings(
        thread: .sample(model: "us.anthropic.claude-sonnet-4-6", effort: .medium), connection: .sampleBedrockPicker()))
}

/// A preview can't open a menu, so the same pickers are laid out here to check the rows'
/// symbols and wording.
#Preview("Permissions popover") {
    var settings = previewSettings(thread: .sample(model: "sonnet", effort: .medium, permissionMode: .acceptEdits))
    settings.offersBypass = true
    return PermissionsForm(settings: settings)
        .popoverSize(width: 320)
}

#Preview("Model and Effort popover") {
    ModelEffortForm(settings: previewSettings(thread: .sample(model: "sonnet", effort: .medium, fastModeState: .on)))
        .popoverSize(width: 300)
}

/// Fable offers four levels and an explicit choice: no stop is the default's.
#Preview("Model and Effort popover (old model selected)") {
    ModelEffortForm(settings: previewSettings(thread: .sample(model: "claude-opus-4-8", effort: .medium)))
        .popoverSize(width: 300)
}

#Preview("Model and Effort popover (effort chosen)") {
    ModelEffortForm(settings: previewSettings(thread: .sample(model: "claude-fable-5-1[1m]", effort: .max)))
        .popoverSize(width: 300)
}

/// No effort chosen: the slider rests on Claude Code's own level, marked as the default.
#Preview("Model and Effort popover (effort default)") {
    ModelEffortForm(settings: previewSettings(thread: .sample(model: "opus", effort: nil)))
        .popoverSize(width: 300)
}

/// A model Claude Code lists without effort levels: the slider is disabled.
#Preview("Model and Effort popover (effort unavailable)") {
    ModelEffortForm(settings: previewSettings(thread: .sample(model: "haiku", effort: nil)))
        .popoverSize(width: 300)
}

/// An id the CLI doesn't list gets a row of its own, with no description.
#Preview("Model and Effort popover (custom model)") {
    ModelEffortForm(settings: previewSettings(thread: .sample(model: "us.anthropic.claude-custom-v1", effort: .medium)))
        .popoverSize(width: 300)
}

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
