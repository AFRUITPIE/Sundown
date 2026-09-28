import Foundation
import Testing
@testable import TetherUI

@Suite
struct OpenFilesTests {
    /// A reply's link to a file names it relative to the chat's directory, with or without a line.
    @Test func fileLinksResolveAgainstTheChatsDirectory() {
        let cwd = "/Users/me/Code/app"
        #expect(OpensFileLinks.path(of: URL(string: "Sources/App.swift")!, in: cwd) == "/Users/me/Code/app/Sources/App.swift")
        #expect(OpensFileLinks.path(of: URL(string: "Sources/App.swift:42")!, in: cwd) == "/Users/me/Code/app/Sources/App.swift")
        #expect(OpensFileLinks.path(of: URL(string: "Sources/App.swift:42:7")!, in: cwd) == "/Users/me/Code/app/Sources/App.swift")
        #expect(OpensFileLinks.path(of: URL(fileURLWithPath: "/tmp/x.txt"), in: cwd) == "/tmp/x.txt")
        #expect(OpensFileLinks.path(of: URL(string: "My%20File.md")!, in: cwd) == "/Users/me/Code/app/My File.md")
        #expect(OpensFileLinks.path(of: URL(string: "https://claude.ai")!, in: cwd) == nil)
        #expect(OpensFileLinks.path(of: URL(string: "Sources/App.swift")!, in: nil) == nil)
    }

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
