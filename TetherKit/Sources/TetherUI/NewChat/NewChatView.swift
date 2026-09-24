import SwiftUI
import TetherKit
import TetherProtocol

/// Compose a new chat: choose the working directory, then send the first message. The host is
/// the one the sidebar shows.
struct NewChatView: View {
    @Bindable var app: AppModel
    @State private var choosingLocalFolder = false
    @State private var choosingRemoteFolder = false

    /// The same host the sidebar shows, so its chats and this draft always agree.
    private var connection: HostConnection? { app.connection }

    var body: some View {
        // No Form: a scrolling Form draws a hard scroll edge under the toolbar, which a chat
        // doesn't have. The folder sits where a chat's status strip goes.
        Color.clear
            .overlay {
                if let connection { NotConnectedView(connection: connection) }
            }
            .safeAreaBar(edge: .bottom) {
                if let connection {
                    VStack(alignment: .leading, spacing: 10) {
                        folderPicker
                        if let error = app.draftError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                        GlassEffectContainer(spacing: 10) {
                            Composer(connection: connection, cwd: app.draftDirectory,
                                     placeholder: app.draftDirectory == nil ? "Choose a folder, then ask Claude…" : "Ask Claude…",
                                     submit: { input in await start(connection, input) })
                        }
                    }
                    .padding(.bottom, 14)
                    // The same column the transcript and its bottom bar use, so the composer doesn't
                    // move sideways when the first message turns this into a chat.
                    .readingColumn()
                }
            }
            .fileImporter(isPresented: $choosingLocalFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { choose(url.path) }
            }
            .sheet(isPresented: $choosingRemoteFolder) {
                if let connection { RemoteFolderPicker(connection: connection) { choose($0) } }
            }
            // `AppModel` seeds the folder with the host's first project; these fill it when the
            // projects arrived after that.
            .onAppear { useFirstProjectIfUnset() }
            .onChange(of: connection?.projects.first?.cwd) { useFirstProjectIfUnset() }
    }

    /// Recent folders, then Other… for any folder.
    private var folderPicker: some View {
        Picker("Folder", selection: Binding(get: { app.draftDirectory }, set: { new in
            if new == Self.otherTag { chooseFolder() } else { choose(new) }
        })) {
            // Only while there is nothing to select: a menu Picker needs a row for its value.
            if app.draftDirectory == nil {
                Text("No Folder").tag(String?.none)
            }
            ForEach(connection?.projects.prefix(15) ?? [], id: \.cwd) { p in
                Text(p.cwd.abbreviatingHome).tag(Optional(p.cwd))
            }
            if let d = app.draftDirectory, !(connection?.projects.contains { $0.cwd == d } ?? false) {
                Text(d.abbreviatingHome).tag(Optional(d))
            }
            Divider()
            Text("Other…").tag(Optional(Self.otherTag))
        }
        .pickerStyle(.menu)
        // Outside a Form the visible label is a separate text, so VoiceOver would hear only the path.
        .accessibilityLabel("Folder")
        .accessibilityIdentifier("newChat.folder")
    }

    /// Not a path: selecting it opens a folder chooser instead of becoming the selection.
    private static let otherTag = "__other__"

    private func choose(_ directory: String?) {
        app.draftDirectory = directory
        app.draftError = nil
    }

    private func useFirstProjectIfUnset() {
        guard app.draftDirectory == nil else { return }
        app.draftDirectory = connection?.projects.first?.cwd
    }

    private func chooseFolder() {
        if connection?.host.isLocal == true { choosingLocalFolder = true } else { choosingRemoteFolder = true }
    }

    private func start(_ connection: HostConnection, _ input: [UserInput]) async {
        guard let cwd = app.draftDirectory else { app.draftError = "Choose a folder first."; return }
        app.draftError = nil
        do {
            let t = try await connection.startThread(cwd: cwd, input: input,
                                                       options: .init(model: app.draftModel, effort: app.draftEffort,
                                                                      permissionMode: app.draftPermissionMode, fastMode: app.draftFastMode))
            app.open(threadID: t.id, on: connection.id)
        } catch {
            app.draftError = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("NewChatView") {
    NavigationStack {
        NewChatView(app: .sample())
    }
    .frame(width: 900, height: 700)
}

#Preview("NewChatView (not connected)") {
    NavigationStack {
        NewChatView(app: .sample(connections: [.sampleFailed()]))
    }
    .frame(width: 900, height: 700)
}

#endif
