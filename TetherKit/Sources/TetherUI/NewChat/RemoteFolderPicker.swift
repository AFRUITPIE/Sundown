import SwiftUI
import TetherKit
import TetherProtocol

/// Browses a remote host's directories (`fs/list`), one level per page of a navigation stack:
/// double-click or Return opens a directory, Back returns, and Choose takes the selected
/// directory, or the one being shown when nothing is selected.
struct RemoteFolderPicker: View {
    let connection: HostConnection
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Where browsing starts: the host's home, or above it by Enclosing Directory.
    @State private var root = ""
    @State private var opened: [String] = []
    /// The selection in the directory being shown; cleared as another is shown.
    @State private var selection: String?

    private var current: String { opened.last ?? root }

    var body: some View {
        NavigationStack(path: $opened) {
            Group {
                if root.isEmpty {
                    ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle")
                } else {
                    level(root)
                }
            }
            .navigationDestination(for: String.self) { level($0) }
        }
        .presentationSizing(.form)
        .onChange(of: opened) { selection = nil }
        .task {
            // The server expands "~" for listing, but thread/start uses cwd as a literal process
            // directory, so the host's actual home is where browsing starts.
            root = connection.serverInfo?.host.home ?? ""
        }
    }

    private func level(_ path: String) -> some View {
        DirectoryLevel(connection: connection, path: path, selection: $selection) { opened.append($0) }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    // Above where browsing started; Back covers the rest.
                    Button("Enclosing Directory", systemImage: "chevron.up") {
                        root = (root as NSString).deletingLastPathComponent
                        opened = []
                    }
                    .disabled(!opened.isEmpty || root == "/")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        done(selection ?? current)
                        dismiss()
                    }
                }
            }
    }
}

/// One directory's subdirectories, loaded when it's shown.
private struct DirectoryLevel: View {
    let connection: HostConnection
    let path: String
    @Binding var selection: String?
    let open: (String) -> Void
    @State private var entries: [FsListResult.Entry]?
    @State private var error: String?

    var body: some View {
        List(entries?.filter(\.isDirectory) ?? [], id: \.path, selection: $selection) { entry in
            Label(entry.name, systemImage: "folder")
        }
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
            if let path = paths.first { open(path) }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Can’t Open", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if entries == nil {
                ProgressView()
            } else if entries?.contains(where: \.isDirectory) == false {
                ContentUnavailableView("No Directories", systemImage: "folder")
            }
        }
        .navigationTitle(path.abbreviatingHome)
        .task(id: path) {
            do {
                entries = try await connection.listDirectory(path)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Choose Directory…: the system's open panel on this Mac, set up for a directory, and the remote
/// picker on an SSH host, which the open panel can't browse.
struct DirectoryChooser: ViewModifier {
    @Binding var isPresented: Bool
    let connection: HostConnection?
    /// Where the open panel starts: the directory chosen now, when there is one.
    let current: String?
    let choose: (String) -> Void

    private var isLocal: Bool { connection?.host.isLocal == true }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: Binding(get: { isPresented && isLocal }, set: { isPresented = $0 }),
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { choose(url.path) }
            }
            .fileDialogConfirmationLabel("Choose")
            .fileDialogMessage("Choose the directory Claude works in.")
            .fileDialogDefaultDirectory(current.map { URL(filePath: $0, directoryHint: .isDirectory) })
            .sheet(isPresented: Binding(get: { isPresented && !isLocal && connection != nil }, set: { isPresented = $0 })) {
                if let connection { RemoteFolderPicker(connection: connection, done: choose) }
            }
    }
}

extension View {
    func directoryChooser(isPresented: Binding<Bool>, connection: HostConnection?, current: String?,
                          choose: @escaping (String) -> Void) -> some View {
        modifier(DirectoryChooser(isPresented: isPresented, connection: connection, current: current, choose: choose))
    }
}

#if DEBUG
#Preview("RemoteFolderPicker") {
    // No client, so `listDirectory` fails fast and the preview shows the error state.
    let connection = HostConnection(host: .local)
    connection.previewSeed(state: .connected)
    return RemoteFolderPicker(connection: connection) { _ in }
        .frame(width: 520, height: 420)
}

#endif
