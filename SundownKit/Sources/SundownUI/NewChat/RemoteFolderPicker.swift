import SwiftUI
import SundownKit
import TetherProtocol

/// Browses a remote host's directories (`fs/list`), one level per page of a navigation stack:
/// double-click or Return opens a directory, the path pop-up above the list goes to any directory
/// above it (as the open panel's does), and Choose takes the selected directory, or the one being
/// shown when nothing is selected. Not toolbar items: a sheet's header draws none on macOS 27, so
/// Enclosing Directory and the stack's Back were never there (2026-10-17).
struct RemoteFolderPicker: View {
    let connection: HostConnection
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Where browsing starts: the host's home, or a directory above it chosen in the path pop-up.
    @State private var root = ""
    @State private var opened: [String] = []
    /// The selection in the directory being shown; cleared as another is shown.
    @State private var selection: String?
    /// Directories that couldn't be listed, which can't be chosen either.
    @State private var unreadable: Set<String> = []

    private var current: String { opened.last ?? root }

    /// Browses from `path`, one of the directories above the one shown.
    private func go(to path: String) {
        guard path != current else { return }
        root = path
        opened = []
        selection = nil
    }

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

    /// The directory shown and every one above it, up to `/`.
    private var ancestors: [String] {
        var paths = [current]
        while let last = paths.last, last != "/", !last.isEmpty {
            paths.append((last as NSString).deletingLastPathComponent)
        }
        return paths
    }

    private func level(_ path: String) -> some View {
        DirectoryLevel(connection: connection, path: path, selection: $selection,
                       failed: { unreadable.insert($0) }) { opened.append($0) }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Directory", selection: Binding(get: { current }, set: { go(to: $0) })) {
                    ForEach(ancestors, id: \.self) { path in
                        Label(path == "/" ? "/" : (path as NSString).lastPathComponent, systemImage: "folder").tag(path)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        done(selection ?? current)
                        dismiss()
                    }
                    .disabled(selection == nil && unreadable.contains(current))
                }
            }
    }
}

/// One directory's subdirectories, loaded when it's shown.
private struct DirectoryLevel: View {
    let connection: HostConnection
    let path: String
    @Binding var selection: String?
    let failed: (String) -> Void
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
            // Not the last directory's entries under this one's title while it loads.
            entries = nil
            error = nil
            do {
                entries = try await connection.listDirectory(path)
            } catch {
                self.error = error.localizedDescription
                failed(path)
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
