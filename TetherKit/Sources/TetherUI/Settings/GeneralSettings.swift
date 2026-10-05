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
                Picker("Directory", selection: $app.appearance.newChatFolder) {
                    ForEach(Appearance.NewChatFolder.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Start in a New Worktree", isOn: $app.appearance.worktreeByDefault)
                // Also turned off by the offer's own Don't Ask Again; here to turn it back on.
                Toggle("Offer to Remove Worktrees", isOn: $app.appearance.offersWorktreeRemoval)
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
    return GeneralSettings(app: app)
        .frame(width: 560, height: 780)
}
#endif
