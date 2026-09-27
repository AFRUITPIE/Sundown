import AppKit
import SwiftUI

extension Appearance.FileEditor {
    /// Newest first; the first one installed is the one used. Zed and Sublime Text each have more
    /// than one app people keep installed.
    var bundleIdentifiers: [String] {
        switch self {
        case .defaultApp: []
        case .xcode: ["com.apple.dt.Xcode"]
        case .visualStudioCode: ["com.microsoft.VSCode"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .nova: ["com.panic.Nova"]
        case .bbedit: ["com.barebones.bbedit"]
        case .sublimeText: ["com.sublimetext.4", "com.sublimetext.3"]
        }
    }

    /// The Open item's title: which app it opens in, once one is chosen.
    var openTitle: String { self == .defaultApp ? "Open" : "Open in \(label)" }

    /// Where this editor is installed; nil for the default app, and for one that isn't. A Launch
    /// Services lookup, so it runs when a file is opened or Settings appears, never in a body.
    @MainActor var applicationURL: URL? {
        bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Opens the file at `path` on this Mac in this editor, or in its default app when this is the
    /// default app or the editor has since been removed.
    @MainActor func open(_ path: String) {
        let file = URL(fileURLWithPath: path)
        guard let app = applicationURL else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// An editor Settings can offer, with the icon Finder shows for it.
struct InstalledEditor: Identifiable {
    let editor: Appearance.FileEditor
    let icon: NSImage
    var id: Appearance.FileEditor { editor }

    /// The editors on this Mac, in the order Settings lists them.
    @MainActor static func all() -> [InstalledEditor] {
        Appearance.FileEditor.allCases.compactMap { editor in
            guard let url = editor.applicationURL else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            // A menu row's image is drawn at its own size.
            icon.size = NSSize(width: 16, height: 16)
            return InstalledEditor(editor: editor, icon: icon)
        }
    }
}

extension String {
    /// The repository `self` (a folder on this Mac) is in, which git's paths are relative to: the
    /// nearest folder up from it with a `.git` in it (a folder, or a worktree's file). Nil when
    /// there is none.
    var enclosingRepository: String? {
        var folder = URL(fileURLWithPath: self).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) { return folder.path }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
    }
}
