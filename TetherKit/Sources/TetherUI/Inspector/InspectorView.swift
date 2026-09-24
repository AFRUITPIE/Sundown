import SwiftUI
import TetherKit

public enum InspectorPane: String, CaseIterable, Identifiable {
    case tasks = "Tasks"
    case session = "Session"
    case mcp = "MCP"

    public var id: Self { self }

    var symbol: String {
        switch self {
        case .tasks: "checklist"
        case .session: "info.circle"
        case .mcp: "puzzlepiece.extension"
        }
    }
}

/// The inspector's content: the selected chat's, or a placeholder so the column is never blank.
struct InspectorView: View {
    @Bindable var app: AppModel
    @Binding var selectedTaskID: String?

    var body: some View {
        if let thread = app.selectedThread, let connection = app.connection {
            ThreadInspector(thread: thread, connection: connection, pane: $app.inspectorPane,
                            selectedTaskID: $selectedTaskID)
                // Already in the inspector: showing a subagent only changes which task is selected.
                .environment(\.inspectSubagent, InspectSubagentAction {
                    selectedTaskID = $0
                    app.inspectorPane = .tasks
                })
        } else {
            ContentUnavailableView("No Session", systemImage: "sidebar.trailing")
        }
    }
}

/// The toolbar chooses the pane. This shell reads nothing off the thread — each pane observes
/// only what it shows, so a streaming delta redraws at most the pane that is open.
struct ThreadInspector: View {
    let thread: ThreadModel
    let connection: HostConnection
    @Binding var pane: InspectorPane
    @Binding private var selectedTaskID: String?

    init(thread: ThreadModel, connection: HostConnection, pane: Binding<InspectorPane>,
         selectedTaskID: Binding<String?> = .constant(nil)) {
        self.thread = thread
        self.connection = connection
        self._pane = pane
        self._selectedTaskID = selectedTaskID
    }

    var body: some View {
        Group {
            switch pane {
            case .tasks: TasksPane(thread: thread, selectedTaskID: $selectedTaskID)
            case .session: SessionPane(thread: thread, connection: connection)
            case .mcp: MCPPane(thread: thread)
            }
        }
        .inspectorPaneStyle()
        .onChange(of: selectedTaskID) {
            if selectedTaskID != nil { pane = .tasks }
        }
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

/// The whole inspector the way `RootView` builds it, from an `AppModel` with a chat selected.
/// The segmented shell itself is shown by each pane's previews, which host `ThreadInspector`.
/// #Preview bodies are result-builder closures (no `if`/control flow), so selection happens here.
@MainActor
private func inspectorPreviewApp() -> AppModel {
    let app = AppModel.sample()
    if let chat = app.connection?.chats.first { app.open(threadID: chat.id) }
    return app
}

#Preview("Inspector (from AppModel)") {
    inspectorPreview {
        InspectorView(app: inspectorPreviewApp(), selectedTaskID: .constant(nil))
    }
}

/// New Chat: no session to inspect, and the column still says so.
#Preview("Inspector (no session)") {
    inspectorPreview {
        InspectorView(app: .sample(), selectedTaskID: .constant(nil))
    }
}
#endif
