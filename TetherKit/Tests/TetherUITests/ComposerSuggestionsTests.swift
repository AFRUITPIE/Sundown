import Testing
import TetherProtocol
@testable import TetherUI

/// The composer's suggestion list is a pure function of the text and the two catalogs it has
/// fetched, so that it can run on change instead of inside `body`.
@Suite
struct ComposerSuggestionsTests {
    private let commands: [SlashCommand] = [
        .init(name: "compact", description: "Compact the conversation"),
        .init(name: "context", description: "Show context usage"),
        .init(name: "resume", description: "Resume a session", terminalOnly: true),
        .init(name: "review", description: "Review the diff"),
    ]

    private func suggestions(_ text: String, files: [String] = []) -> [Composer.Suggestion] {
        Composer.matchingSuggestions(for: text, commands: commands, fileMatches: files)
    }

    /// Esc closes an open `/` or `@` list before it stops a running turn.
    @Test func escapeClosesTheListBeforeStopping() {
        #expect(Composer.escapeAction(suggestionsShowing: true, canStop: true) == .closeSuggestions)
        #expect(Composer.escapeAction(suggestionsShowing: true, canStop: false) == .closeSuggestions)
        #expect(Composer.escapeAction(suggestionsShowing: false, canStop: true) == .stop)
        #expect(Composer.escapeAction(suggestionsShowing: false, canStop: false) == .ignore)
    }

    @Test func plainTextOffersNothing() {
        #expect(suggestions("").isEmpty)
        #expect(suggestions("explain the reducer").isEmpty)
        // A command already typed out is being written, not being chosen.
        #expect(suggestions("/compact now").isEmpty)
        #expect(suggestions("/compact\nand then").isEmpty)
    }

    @Test func slashOffersEveryUsableCommand() {
        let all = suggestions("/")
        #expect(all.map(\.title) == ["/compact", "/context", "/review"], "terminal-only commands can't be run from here")
        #expect(all.first?.completion == "/compact ")
        #expect(all.first?.detail == "Compact the conversation")
        #expect(all.first?.symbol == "terminal")
    }

    @Test func slashFiltersCaseInsensitively() {
        #expect(suggestions("/CON").map(\.title) == ["/context"])
        #expect(suggestions("/re").map(\.title) == ["/review"])
        #expect(suggestions("/nothingLikeThis").isEmpty)
    }

    @Test func listsAreCapped() {
        let many = (0..<40).map { SlashCommand(name: "cmd\($0)", description: "") }
        #expect(Composer.matchingSuggestions(for: "/", commands: many, fileMatches: []).count == 12)
        let files = (0..<40).map { "file\($0).swift" }
        #expect(Composer.matchingSuggestions(for: "@f", commands: [], fileMatches: files).count == 12)
    }

    @Test func mentionCompletesTheLastWordAndKeepsTheRest() {
        let matches = ["TetherKit/Sources/", "TetherKit/Sources/TetherUI/Composer.swift"]
        let out = suggestions("look at @Compo", files: matches)
        #expect(out.map(\.completion) == [
            "look at @TetherKit/Sources/ ",
            "look at @TetherKit/Sources/TetherUI/Composer.swift ",
        ])
        // A folder and a file are told apart by the trailing slash the server sends.
        #expect(out.map(\.symbol) == ["folder", "doc"])
    }

    @Test func mentionOnlyAppliesToTheWordBeingTyped() {
        #expect(suggestions("@Composer.swift is where", files: ["Composer.swift"]).isEmpty)
    }
}
