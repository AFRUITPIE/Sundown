import AppKit
import SwiftUI

/// The things the app asks of the Mac that SwiftUI has no API for, kept here so AppKit isn't
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

/// A help tag over a view drawn on Liquid Glass. SwiftUI's `help` shows nothing there on macOS 27:
/// the glass's own view is what's under the pointer. A transparent AppKit view above it carries the
/// tag, and passes every click through to what's under it.
struct GlassHelp: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView { HelpView() }

    func updateNSView(_ view: NSView, context: Context) { view.toolTip = text }

    private final class HelpView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// `help`, on glass. The tag's view is the pointer's alone: VoiceOver and accessibility's hit
    /// testing reach the control under it (which `help` names), not an empty view over it.
    func glassHelp(_ text: String) -> some View {
        help(text).overlay { GlassHelp(text: text).accessibilityHidden(true) }
    }
}
