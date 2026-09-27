import SwiftUI
import TetherKit

/// The inspector's content: the selected chat's, or a placeholder so the column is never blank.
struct InspectorView: View {
    @Bindable var window: WindowModel
    @Binding var selectedTaskID: String?
    /// The pane tabs over the pane; not in the inspector column, whose toolbar holds them.
    var showsPicker = true

    var body: some View {
        if let thread = window.selectedThread, let connection = window.connection {
            ThreadInspector(thread: thread, connection: connection, pane: $window.inspectorPane,
                            selectedTaskID: $selectedTaskID, showsPicker: showsPicker)
        } else {
            ContentUnavailableView("No Session", systemImage: "sidebar.trailing")
        }
    }
}

/// A chat's inspector: tabs for its panes over the pane that is open. Reads nothing off the thread
/// itself: each pane observes only what it shows, so a streaming delta redraws at most that pane.
struct ThreadInspector: View {
    let thread: ThreadModel
    let connection: HostConnection
    /// Changes for a preview, which has no repository to read.
    @Environment(\.previewChanges) private var previewChanges
    @Binding var pane: InspectorPane
    @Binding var selectedTaskID: String?

    /// The pane tabs over the pane; not when the toolbar's tabs already choose it.
    var showsPicker = true

    init(thread: ThreadModel, connection: HostConnection, pane: Binding<InspectorPane> = .constant(.tasks),
         selectedTaskID: Binding<String?> = .constant(nil), showsPicker: Bool = true) {
        self.thread = thread
        self.connection = connection
        self._pane = pane
        self._selectedTaskID = selectedTaskID
        self.showsPicker = showsPicker
    }

    var body: some View {
        Group {
            switch pane {
            case .tasks: TasksPane(thread: thread, connection: connection, selectedTaskID: $selectedTaskID)
            case .session: SessionPane(thread: thread, connection: connection)
            case .mcp: MCPPane(thread: thread, connection: connection)
            case .changes: ChangesPane(thread: thread, connection: connection, changes: previewChanges)
            }
        }
        .inspectorPaneStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A bar, so a pane's form scrolls under it with the standard edge effect.
        .safeAreaBar(edge: .top) {
            if showsPicker { panePicker }
        }
    }

    private var panePicker: some View {
        Group {
            // `.tabs` rather than `.segmented`: it switches views rather than choosing a value,
            // and VoiceOver announces the options as tabs.
            Picker("Inspector", selection: $pane) {
                ForEach(InspectorPane.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.tabs)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// The inspector's panes as a segmented control of their symbols, in the inspector column's own
/// toolbar, as Xcode shows its inspectors'. Each segment is named for VoiceOver and its help tag.
struct InspectorPanePicker: View {
    @Binding var pane: InspectorPane

    var body: some View {
        Picker("Inspector", selection: $pane) {
            ForEach(InspectorPane.allCases) { pane in
                Label(pane.label, systemImage: pane.symbol).tag(pane).help(pane.label)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
    }
}

/// One pane as a whole tab of the window (Settings ▸ Advanced ▸ Inspector ▸ Tabs): the chat's, or
/// a placeholder on New Chat. The chat's title stays the window's.
struct PaneTab: View {
    @Bindable var window: WindowModel
    let pane: InspectorPane

    var body: some View {
        Group {
            if let thread = window.selectedThread, let connection = window.connection {
                ThreadInspector(thread: thread, connection: connection, pane: .constant(pane),
                                selectedTaskID: $window.inspectedTaskID, showsPicker: false)
            } else {
                ContentUnavailableView("No Session", systemImage: pane.symbol)
            }
        }
        .navigationTitle(window.selectedThread?.title ?? "New Chat")
        .navigationSubtitle(window.subtitle)
    }
}

/// The inspector's show/hide button: plain, like Xcode's, so it doesn't tint while the inspector
/// is open. Declared by the inspector column, so it sits above it, and stays in the toolbar when
/// the inspector is elsewhere (Settings ▸ Advanced ▸ Inspector).
struct InspectorToggle: View {
    @Bindable var window: WindowModel

    var body: some View {
        Button("Inspector", systemImage: window.app.appearance.inspector.symbol) {
            window.inspectorShown.toggle()
        }
        .help(window.inspectorShown ? "Hide Inspector" : "Show Inspector")
    }
}

extension Appearance.InspectorPlacement {
    /// The toggle's symbol: where the inspector will appear.
    var symbol: String {
        switch self {
        case .column: "sidebar.trailing"
        case .panel: "macwindow.on.rectangle"
        case .drawer: "rectangle.bottomthird.inset.filled"
        case .overlay: "rectangle.inset.topright.filled"
        case .tabs: "rectangle.split.3x1"
        }
    }
}

/// The inspector as a floating panel (Settings ▸ Advanced ▸ Inspector ▸ Floating Panel): a
/// `UtilityWindow` that shows the front window's chat, so the chat window itself never changes
/// width. It follows `AppModel.activeWindow`: a panel doesn't get the main window's focused values.
public struct InspectorPanel: View {
    public static let id = "inspector"
    let app: AppModel
    private var window: WindowModel? { app.activeWindow }

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        Group {
            if let window {
                InspectorPanelContent(window: window)
            } else {
                ContentUnavailableView("No Window", systemImage: "macwindow")
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity, minHeight: 320, idealHeight: 540, maxHeight: .infinity)
        .environment(\.appearance, app.appearance)
        .environment(\.textScale, app.textScale)
        .environment(\.openFilesWith, app.appearance.openFilesWith)
        .onAppear { app.inspectorPanelShown = true }
        .onDisappear { app.inspectorPanelShown = false }
    }
}

private struct InspectorPanelContent: View {
    @Bindable var window: WindowModel

    var body: some View {
        InspectorView(window: window, selectedTaskID: $window.inspectedTaskID)
            .environment(\.hostIsLocal, window.connection?.host.isLocal == true)
    }
}

/// Where Settings ▸ Advanced ▸ Inspector ▸ Over the Chat puts its card: over the content it's
/// applied to, inside that content's safe area, so it clears a bottom bar added after it.
struct InspectorCardOverlay: ViewModifier {
    @Environment(\.inspectorCardWindow) private var window

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let window, window.app.appearance.inspector == .overlay, window.showInspector {
                InspectorCard(window: window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: shown)
    }

    private var shown: Bool { window.map { $0.app.appearance.inspector == .overlay && $0.showInspector } ?? false }
}

extension View {
    func inspectorCardOverlay() -> some View { modifier(InspectorCardOverlay()) }
}

extension EnvironmentValues {
    /// The window whose inspector card a chat or New Chat shows, set by the detail column.
    @Entry var inspectorCardWindow: WindowModel?
}

/// The inspector over the chat's trailing edge (Settings ▸ Advanced ▸ Inspector ▸ Over the Chat):
/// a glass card, so the transcript underneath keeps its width and never re-wraps.
struct InspectorCard: View {
    @Bindable var window: WindowModel

    var body: some View {
        InspectorView(window: window, selectedTaskID: $window.inspectedTaskID)
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 18))
            .glassEffect(in: .rect(cornerRadius: 18))
            .padding(12)
    }
}

/// The inspector under the chat (Settings ▸ Advanced ▸ Inspector ▸ Drawer): its height changes,
/// never the transcript's width, like Xcode's debug area.
struct InspectorDrawer: View {
    @Bindable var window: WindowModel

    var body: some View {
        InspectorView(window: window, selectedTaskID: $window.inspectedTaskID)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 160, idealHeight: 280, maxHeight: .infinity)
            .background(.background)
    }
}

extension EnvironmentValues {
    @Entry var previewChanges: WorkingChanges?
}

extension View {
    /// What every pane is dressed in, applied once by the shell — and by a preview showing a pane
    /// on its own, so the two can't drift.
    func inspectorPaneStyle() -> some View {
        formStyle(.grouped)
            // Let the inspector's material show through instead of the grouped Form's background.
            .scrollContentBackground(.hidden)
            // Values truncate instead of widening the column (a min width > max width loops the split view).
            .lineLimit(1)
    }
}

/// An inspector pane with nothing in it yet — says which, rather than showing a blank column.
/// Title only: what it would explain, the title already said.
struct InspectorEmptyState: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
/// The inspector as the window hosts it: attached to a split view, at the app's column width.
@MainActor
func inspectorPreview<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    NavigationSplitView {
        Text("Sidebar")
    } detail: {
        Text("Detail").foregroundStyle(.secondary)
    }
    .inspector(isPresented: .constant(true)) {
        content()
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .frame(width: 900, height: 640)
}

/// The whole inspector the way `RootView` builds it, from a window with a chat selected.
/// The segmented shell itself is shown by each pane's previews, which host `ThreadInspector`.
/// #Preview bodies are result-builder closures (no `if`/control flow), so selection happens here.
@MainActor
private func inspectorPreviewWindow() -> WindowModel {
    let app = AppModel.sample()
    return .sample(app, threadID: app.connection(app.lastHostID)?.chats.first?.id)
}

#Preview("Inspector (from AppModel)") {
    inspectorPreview {
        InspectorView(window: inspectorPreviewWindow(), selectedTaskID: .constant(nil))
    }
}

/// New Chat: no session to inspect, and the column still says so.
#Preview("Inspector (no session)") {
    inspectorPreview {
        InspectorView(window: .sample(), selectedTaskID: .constant(nil))
    }
}
#endif
