import SwiftUI
import TetherKit

/// The inspector's content: the selected chat's, or a placeholder so the column is never blank.
struct InspectorView: View {
    @Bindable var window: WindowModel
    @Binding var selectedTaskID: String?

    var body: some View {
        if let thread = window.selectedThread, let connection = window.connection {
            ThreadInspector(thread: thread, connection: connection, pane: $window.inspectorPane,
                            selectedTaskID: $selectedTaskID)
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
    @Binding var pane: InspectorPane
    @Binding var selectedTaskID: String?

    init(thread: ThreadModel, connection: HostConnection, pane: Binding<InspectorPane> = .constant(.tasks),
         selectedTaskID: Binding<String?> = .constant(nil)) {
        self.thread = thread
        self.connection = connection
        self._pane = pane
        self._selectedTaskID = selectedTaskID
    }

    var body: some View {
        Group {
            switch pane {
            case .tasks: TasksPane(thread: thread, connection: connection, selectedTaskID: $selectedTaskID)
            case .session: SessionPane(thread: thread, connection: connection)
            case .mcp: MCPPane(thread: thread, connection: connection)
            }
        }
        .inspectorPaneStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A bar, so a pane's form scrolls under it with the standard edge effect.
        .safeAreaBar(edge: .top) {
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

/// The inspector's show/hide button: plain, like Xcode's, so it doesn't tint while the inspector
/// is open. Declared by the inspector, so it sits above the column.
struct InspectorToggle: View {
    @Bindable var window: WindowModel

    var body: some View {
        Button("Inspector", systemImage: "sidebar.trailing") {
            window.showInspector.toggle()
        }
        .help(window.showInspector ? "Hide tasks, session details and MCP servers" : "Show tasks, session details and MCP servers")
    }
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
