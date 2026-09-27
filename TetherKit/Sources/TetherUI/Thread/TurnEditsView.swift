import SwiftUI
import TetherKit
import TetherProtocol

/// The files a finished turn edited, after its last reply, as quiet as a tool row: "Edited 3 files
/// +42 −7", counted from the turn's own edits (`TurnEdits`). Open, one line per file, each opening
/// to its diff beneath it, and Restore Files…, which puts the files back as they were before the
/// turn's prompt (Restore Code to Here…'s preview and confirmation). Nothing indents.
struct TurnEditsView: View {
    let edits: TurnEdits
    /// The chat's folder, which each file's folder is shown relative to.
    let cwd: String?
    @State private var expanded: Bool
    @State private var openFiles: Set<String>
    @Environment(\.restoreCode) private var restoreCode

    init(edits: TurnEdits, cwd: String?, expanded: Bool = false, openFiles: Set<String> = []) {
        self.edits = edits
        self.cwd = cwd
        _expanded = State(initialValue: expanded)
        _openFiles = State(initialValue: openFiles)
    }

    private var title: String {
        edits.files.count == 1 ? "Edited 1 file" : "Edited \(edits.files.count) files"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).foregroundStyle(.secondary)
                    LineCounts(added: edits.added, removed: edits.removed)
                    Spacer(minLength: 8)
                    DisclosureIndicator(expanded: expanded)
                }
                .scaledFont(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(LineCounts.description(added: edits.added, removed: edits.removed))
            if expanded {
                ForEach(edits.files) { file in
                    EditedFileRow(file: file, cwd: cwd, isOpen: openFiles.contains(file.path)) {
                        withAnimation(.snappy(duration: 0.15)) {
                            if openFiles.remove(file.path) == nil { openFiles.insert(file.path) }
                        }
                    }
                }
                Button("Restore Files…") { restoreCode(edits.promptID) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .scaledFont(.callout)
                    .help("Put these files back as they were before this turn’s message")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// One file a turn edited: its name, the folder it's in, what the turn added and removed, and,
/// open, the turn's edits to it as diffs.
private struct EditedFileRow: View {
    let file: TurnEdits.File
    let cwd: String?
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.hostIsLocal) private var hostIsLocal
    @Environment(\.openFilesWith) private var editor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(file.path.lastPathComponent).foregroundStyle(.secondary)
                    Text(folder).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 8)
                    LineCounts(added: file.added, removed: file.removed)
                    DisclosureIndicator(expanded: isOpen)
                }
                .scaledFont(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.path.abbreviatingHome)
            .accessibilityLabel(file.path.lastPathComponent)
            .accessibilityValue(LineCounts.description(added: file.added, removed: file.removed))
            .contextMenu {
                if hostIsLocal {
                    Button(editor.openTitle) { editor.open(file.path) }
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") }
                    Divider()
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            if isOpen {
                ForEach(Array(file.changes.enumerated()), id: \.offset) { _, change in
                    DiffView(old: change.old, new: change.new)
                }
            }
        }
    }

    /// The file's folder within the chat's, or from the home folder when it's elsewhere; nothing
    /// for a file at the top of the chat's folder.
    private var folder: String {
        let directory = (file.path as NSString).deletingLastPathComponent
        if let cwd, directory == cwd { return "" }
        if let cwd, directory.hasPrefix(cwd + "/") { return String(directory.dropFirst(cwd.count + 1)) }
        return directory.abbreviatingHome
    }
}

/// Lines added and removed, "+42 −7", in the diff colors; a side with none is left out.
struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text(verbatim: "\u{2212}\(removed)").foregroundStyle(.red) }
        }
        .scaledFont(.caption)
        .monospacedDigit()
        // The row it's in says it in words.
        .accessibilityHidden(true)
    }

    static func description(added: Int, removed: Int) -> String {
        "\(added) \(added == 1 ? "line" : "lines") added, \(removed) removed"
    }
}

#if DEBUG
/// A turn's edits as `ThreadModel` summarizes them: two edits to one file, a new file, and one
/// elsewhere in the chat's folder.
@MainActor
private func sampleTurnEdits() -> TurnEdits {
    let thread = ThreadModel.sampleWorkChat()
    let rows = thread.rows(.summarized)
    for case .turnEdits(let edits) in rows where edits.files.count > 1 { return edits }
    fatalError("the work chat's sample has no turn with edits")
}

#Preview("Edited files (collapsed)") {
    TurnEditsView(edits: sampleTurnEdits(), cwd: "/Users/hayden/Code/tether-app")
        .scaledFont(.body)
        .padding(20)
        .frame(width: 560)
}

#Preview("Edited files (expanded)") {
    TurnEditsView(edits: sampleTurnEdits(), cwd: "/Users/hayden/Code/tether-app", expanded: true)
        .scaledFont(.body)
        .padding(20)
        .frame(width: 560)
}

/// One file open to its diffs: the turn's two edits to it, in the order they were made.
#Preview("Edited files (a file open)") {
    let edits = sampleTurnEdits()
    return TurnEditsView(edits: edits, cwd: "/Users/hayden/Code/tether-app", expanded: true,
                         openFiles: [edits.files[0].path])
        .scaledFont(.body)
        .padding(20)
        .frame(width: 560, height: 520, alignment: .top)
}
#endif
