import SwiftUI
import TetherKit
import TetherProtocol

/// Compose a new chat: choose the working directory, then send the first message. The host is
/// the one the sidebar shows.
struct NewChatView: View {
    @Bindable var window: WindowModel
    @State private var choosingLocalFolder = false
    @State private var choosingRemoteFolder = false

    /// The same host the sidebar shows, so its chats and this draft always agree.
    private var connection: HostConnection? { window.connection }

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
                        if let error = window.draftError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                        GlassEffectContainer(spacing: 10) {
                            Composer(connection: connection, cwd: window.draftDirectory,
                                     draftKey: "new-chat:\(window.hostID)",
                                     placeholder: window.draftDirectory == nil ? "Choose a folder, then ask Claude…" : "Ask Claude…",
                                     submit: { input in await start(connection, input) })
                        }
                    }
                    .padding(.bottom, 14)
                    .scaledFont(.body)
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
            // A folder dragged from Finder is where the chat starts; this Mac's folders only.
            .dropDestination(for: URL.self) { urls, _ in
                guard connection?.host.isLocal == true, let folder = urls.first(where: \.hasDirectoryPath) else { return false }
                choose(folder.path)
                return true
            }
            .onAppear { useFirstProjectIfUnset() }
            .onChange(of: connection?.projects.first?.cwd) { useFirstProjectIfUnset() }
    }

    /// Recent folders, then Other… for any folder.
    private var folderPicker: some View {
        Picker("Folder", selection: Binding(get: { window.draftDirectory }, set: { new in
            if new == Self.otherTag { chooseFolder() } else { choose(new) }
        })) {
            // Only while there is nothing to select: a menu Picker needs a row for its value.
            if window.draftDirectory == nil {
                Text("No Folder").tag(String?.none)
            }
            ForEach(connection?.projects.prefix(15) ?? [], id: \.cwd) { p in
                Text(p.cwd.abbreviatingHome).tag(Optional(p.cwd))
            }
            if let d = window.draftDirectory, !(connection?.projects.contains { $0.cwd == d } ?? false) {
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
        window.draftDirectory = directory
        window.draftError = nil
    }

    private func useFirstProjectIfUnset() {
        guard window.draftDirectory == nil else { return }
        window.draftDirectory = connection?.projects.first?.cwd
    }

    private func chooseFolder() {
        if connection?.host.isLocal == true { choosingLocalFolder = true } else { choosingRemoteFolder = true }
    }

    private func start(_ connection: HostConnection, _ input: [UserInput]) async {
        guard let cwd = window.draftDirectory else { window.draftError = "Choose a folder first."; return }
        window.draftError = nil
        do {
            let t = try await connection.startThread(cwd: cwd, input: input,
                                                       options: .init(model: window.draftModel, effort: window.draftEffort,
                                                                      permissionMode: window.draftPermissionMode, fastMode: window.draftFastMode))
            window.open(threadID: t.id, on: connection.id)
        } catch {
            window.draftError = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("NewChatView") {
    NavigationStack {
        NewChatView(window: .sample())
    }
    .frame(width: 900, height: 700)
}

#Preview("NewChatView (not connected)") {
    NavigationStack {
        NewChatView(window: .sample(.sample(connections: [.sampleFailed()])))
    }
    .frame(width: 900, height: 700)
}

#endif
