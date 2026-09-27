import Foundation
import Testing
@testable import TetherUI

@Suite
struct OpenFilesTests {
    @Test func openSaysWhereOnceAnEditorIsChosen() {
        #expect(Appearance.FileEditor.defaultApp.openTitle == "Open")
        #expect(Appearance.FileEditor.visualStudioCode.openTitle == "Open in Visual Studio Code")
    }

    @Test func everyEditorButTheDefaultHasAnApp() {
        for editor in Appearance.FileEditor.allCases {
            #expect(editor.bundleIdentifiers.isEmpty == (editor == .defaultApp), "\(editor)")
        }
    }

    /// git's paths are relative to the repository's top, which a chat's folder may be below; a
    /// worktree's `.git` is a file rather than a folder.
    @Test func theRepositoryIsFoundAboveTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tether-repo-\(UUID().uuidString)")
        let nested = root.appending(path: "Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = nested.path.enclosingRepository

        try Data("gitdir: /elsewhere\n".utf8).write(to: root.appending(path: ".git"))

        #expect(nested.path.enclosingRepository == root.standardizedFileURL.path)
        #expect(root.path.enclosingRepository == root.standardizedFileURL.path)
        // Before the `.git` existed, nothing above the temporary folder was a repository.
        #expect(outside == nil)
    }
}
