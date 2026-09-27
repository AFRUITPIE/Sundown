import SwiftUI

/// Settings ▸ Appearance: every choice behind how the transcript, tool calls, motion, composer and
/// sidebar look and behave. Each applies at once, to every window, so a chat beside this window
/// shows the difference as it's chosen.
struct AppearanceSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("Transcript") {
                Picker("Reading Width", selection: $app.transcriptWidth) {
                    ForEach(TranscriptWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Text Size", selection: $app.textScale) {
                    ForEach(TextScale.steps, id: \.self) { Text(TextScale.label($0)).tag($0) }
                }
                Picker("Density", selection: $app.appearance.density) {
                    ForEach(Appearance.Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Reply Font", selection: $app.appearance.replyFont) {
                    ForEach(Appearance.ReplyFont.allCases) { font in
                        Text(font.label).fontDesign(font.design).tag(font)
                    }
                }
                Picker("Your Messages", selection: $app.appearance.promptStyle) {
                    ForEach(Appearance.PromptStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Timestamps", selection: $app.appearance.timestamps) {
                    ForEach(Appearance.Timestamps.allCases) { Text($0.label).tag($0) }
                }
                Picker("Message Actions", selection: $app.appearance.messageActions) {
                    ForEach(Appearance.MessageActions.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Wrap Long Lines in Code", isOn: $app.appearance.wrapCode)
            }

            Section("Tool Calls") {
                Toggle("Group Finished Calls", isOn: $app.appearance.groupToolCalls)
                Toggle("Show Icons", isOn: $app.appearance.toolIcons)
                Picker("Status", selection: $app.appearance.statusSide) {
                    ForEach(Appearance.Side.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Disclosure Chevron", selection: $app.appearance.chevronSide) {
                    ForEach(Appearance.Side.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show How Long a Call Has Run", isOn: $app.appearance.showElapsed)
                Toggle("Open Failed Calls", isOn: $app.appearance.expandFailures)
            }

            Section {
                Toggle("Fade In Streamed Text", isOn: $app.appearance.fadeInText)
                Toggle("Fade In New Messages and Calls", isOn: $app.appearance.fadeInRows)
                Picker("Follow a Reply", selection: $app.appearance.followMotion) {
                    ForEach(Appearance.FollowMotion.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show “Thinking…” Before a Reply", isOn: $app.appearance.showThinking)
            } header: {
                Text("Motion")
            } footer: {
                Text("With Reduce Motion on in System Settings, a reply is followed without gliding.")
            }

            Section("Composer") {
                Picker("Layout", selection: $app.appearance.composerLayout) {
                    ForEach(Appearance.ComposerLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Send With", selection: $app.appearance.sendShortcut) {
                    ForEach(Appearance.SendShortcut.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Offer Prompt Suggestions", isOn: $app.appearance.promptSuggestions)
                Toggle("Show How Full the Context Is", isOn: $app.appearance.contextRing)
            }

            Section("Sidebar") {
                Picker("Group Chats By", selection: $app.sidebarGrouping) {
                    ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Chat Rows Show", selection: $app.appearance.rowDetail) {
                    ForEach(Appearance.RowDetail.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Mark Chats Claude Is Working In", isOn: $app.appearance.runningIndicator)
            }

            Section {
                Button("Restore Defaults") { app.appearance = Appearance() }
                    .disabled(app.appearance == Appearance())
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
#Preview("Appearance") {
    AppearanceSettings(app: .sample())
        .frame(width: 560, height: 900)
}
#endif
