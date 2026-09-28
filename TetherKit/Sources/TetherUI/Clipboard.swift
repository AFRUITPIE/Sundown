import AppKit

/// The two things the app asks of the Mac that SwiftUI has no API for, kept here so AppKit isn't
/// reached for anywhere else.
///
/// A Copy button or menu item writes the Clipboard itself: SwiftUI's `copyable` answers only
/// Edit ▸ Copy, and its documentation says a custom Copy action updates `NSPasteboard` directly.
enum Clipboard {
    @MainActor static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Show in Finder: SwiftUI can open a file (`openURL`), but not show where one is.
enum Finder {
    /// A Finder window with the file selected in its directory.
    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    /// A Finder window showing the directory's contents.
    @MainActor static func show(directory: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
    }
}
