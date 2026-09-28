import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

/// Links in a reply that name a file — `Sources/App.swift`, `App.swift:42`, `README.md#install`,
/// a `file:` URL — open it in Settings ▸ General ▸ Open Files With, found relative to the chat's
/// directory, on this Mac. Anything that would run rather than open (an app, a script, a Terminal
/// file, an installer) is shown in Finder instead: a link's words don't show where it goes. Any
/// other link, or one on another host, goes where the system sends it.
struct OpensFileLinks: ViewModifier {
    let cwd: String?
    @Environment(\.hostIsLocal) private var hostIsLocal
    @Environment(\.openFilesWith) private var editor

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard hostIsLocal, let path = Self.path(of: url, in: cwd),
                  FileManager.default.fileExists(atPath: path) else { return .systemAction }
            let file = URL(filePath: path)
            if Self.runs(file) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                editor.open(path)
            }
            return .handled
        })
    }

    /// The file a link names, if it names one: a `file:` URL, or a path with no scheme (a file name
    /// with a line, `App.swift:42`, reads as one), relative to `cwd` unless it's absolute, without
    /// a `#fragment`, `?query` or trailing `:line` or `:line:column`.
    nonisolated static func path(of url: URL, in cwd: String?) -> String? {
        var raw: String
        if url.isFileURL {
            raw = url.path
        } else if url.scheme == nil || url.scheme?.contains(".") == true {
            raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        } else {
            return nil
        }
        if let cut = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) { raw = String(raw[..<cut]) }
        let trimmed = raw.replacing(/(:\d+){1,2}$/, with: "")
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return trimmed }
        if trimmed.hasPrefix("~") { return (trimmed as NSString).expandingTildeInPath }
        guard let cwd else { return nil }
        return (cwd as NSString).appendingPathComponent(trimmed)
    }

    /// Whether opening `file` would run something: an app or other bundle, an executable, a script,
    /// or a file macOS hands to Terminal or Installer.
    nonisolated static func runs(_ file: URL) -> Bool {
        let values = try? file.resourceValues(forKeys: [.isPackageKey, .isApplicationKey, .isExecutableKey, .isDirectoryKey, .contentTypeKey])
        if values?.isApplication == true || values?.isPackage == true { return true }
        if values?.isDirectory != true, values?.isExecutable == true { return true }
        if let type = values?.contentType, type.conforms(to: .executable) || type.conforms(to: .script) { return true }
        let runnable: Set<String> = ["command", "terminal", "tool", "pkg", "mpkg", "workflow", "action", "scpt", "applescript", "inetloc", "webloc", "fileloc"]
        return runnable.contains(file.pathExtension.lowercased())
    }
}

extension View {
    /// Dragged, the file at `path` on this Mac, as Finder drags it; nothing on another host.
    @ViewBuilder func draggableFile(_ path: String?) -> some View {
        if let path {
            draggable(URL(filePath: path))
        } else {
            self
        }
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
