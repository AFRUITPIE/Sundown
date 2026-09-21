import SwiftUI
import TetherKit
import TetherProtocol

/// Compose a new chat: choose the host and working directory, then send the first message.
struct NewChatView: View {
    @Bindable var app: AppModel
    @State private var directory: String?
    @State private var error: String?
    @State private var choosingLocalFolder = false
    @State private var choosingRemoteFolder = false

    /// The same host the sidebar shows, so its chats and this draft always agree.
    private var connection: HostConnection? { app.connection }

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: $app.hostID) {
                    ForEach(app.hosts) { Text($0.name).tag($0.id) }
                }
                Picker("Folder", selection: Binding(get: { directory }, set: { new in
                    if new == "__choose__" { chooseFolder() } else { directory = new }
                })) {
                    Text("Choose a folder").tag(String?.none)
                    ForEach(connection?.projects.prefix(15) ?? [], id: \.cwd) { p in
                        Text(p.cwd.abbreviatingHome).tag(Optional(p.cwd))
                    }
                    if let d = directory, !(connection?.projects.contains { $0.cwd == d } ?? false) {
                        Text(d.abbreviatingHome).tag(Optional(d))
                    }
                    Divider()
                    Text("Choose…").tag(Optional("__choose__"))
                }
            } footer: {
                if let e = error { Text(e).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaBar(edge: .bottom) {
            if let connection {
                // The same column the transcript and its bottom bar use, so the composer doesn't
                // move sideways when the first message turns this screen into a chat.
                GlassEffectContainer(spacing: 10) {
                    Composer(connection: connection, cwd: directory, placeholder: directory == nil ? "Choose a folder, then ask Claude…" : "Ask Claude…", submit: { input in
                        await start(connection, input)
                    })
                }
                .padding(.bottom, 14)
                .readingColumn()
            }
        }
        .fileImporter(isPresented: $choosingLocalFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { directory = url.path }
        }
        .sheet(isPresented: $choosingRemoteFolder) {
            if let connection { RemoteFolderPicker(connection: connection) { directory = $0 } }
        }
        // Projects usually arrive after this appears.
        .onAppear { useFirstProjectIfUnset() }
        .onChange(of: connection?.projects.first?.cwd) { useFirstProjectIfUnset() }
        .onChange(of: app.hostID) {
            directory = nil
            useFirstProjectIfUnset()
        }
    }

    private func useFirstProjectIfUnset() {
        guard directory == nil else { return }
        directory = connection?.projects.first?.cwd
    }

    private func chooseFolder() {
        if connection?.host.isLocal == true { choosingLocalFolder = true } else { choosingRemoteFolder = true }
    }

    private func start(_ connection: HostConnection, _ input: [UserInput]) async {
        guard let cwd = directory else { error = "Choose a folder first."; return }
        do {
            let t = try await connection.startThread(cwd: cwd, input: input,
                                                       options: .init(model: app.draftModel, effort: app.draftEffort,
                                                                      permissionMode: app.draftPermissionMode, fastMode: app.draftFastMode))
            app.open(threadID: t.id, on: connection.id)
        } catch {
            self.error = error.localizedDescription
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

#endif
