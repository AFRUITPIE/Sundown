import SwiftUI

/// Settings ▸ Advanced: the layouts still being compared. Each applies at once, to every window,
/// so a chat beside Settings shows the difference as it's chosen.
struct AdvancedSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("Window") {
                Picker("Inspector", selection: $app.appearance.inspector) {
                    ForEach(Appearance.InspectorPlacement.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Sidebar") {
                Picker("Layout", selection: $app.appearance.sidebar) {
                    ForEach(Appearance.SidebarStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Transcript") {
                Picker("Tool Calls", selection: $app.appearance.toolCalls) {
                    ForEach(Appearance.ToolCallDisplay.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Button("Restore Defaults") { app.appearance.restoreAdvanced() }
                    .disabled(app.appearance.advancedIsDefault)
            }
        }
        .formStyle(.grouped)
    }
}

extension Appearance {
    /// Puts back the Advanced pane's choices, leaving General's.
    mutating func restoreAdvanced() {
        let d = Appearance()
        toolCalls = d.toolCalls
        sidebar = d.sidebar
        inspector = d.inspector
    }

    var advancedIsDefault: Bool {
        var restored = self
        restored.restoreAdvanced()
        return restored == self
    }
}

#if DEBUG
#Preview("Advanced") {
    AdvancedSettings(app: .sample())
        .frame(width: 560, height: 400)
}
#endif
