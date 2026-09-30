import Testing
import TetherProtocol
@testable import TetherUI

@Suite
struct ContextBreakdownTests {
    /// Used categories take colors in order and sit end to end from the start; the reserve sits at
    /// the end, and free space and deferred tools aren't drawn.
    @Test func categoriesAreClassifiedByKindAndLaidEndToEnd() throws {
        let usage: JSONValue = [
            "totalTokens": 30, "maxTokens": 100,
            "categories": [
                ["name": "System prompt", "tokens": 10, "kind": "used"],
                ["name": "Messages", "tokens": 20, "kind": "used"],
                ["name": "Free space", "tokens": 50, "kind": "free"],
                ["name": "Autocompact buffer", "tokens": 20, "kind": "buffer"],
                ["name": "MCP tools (deferred)", "tokens": 5, "kind": "deferred"],
            ],
        ]
        let b = try #require(ContextBreakdown(usage))
        #expect(b.categories.map(\.kind) == [.used(0), .used(1), .free, .buffer, .deferred])
        #expect(b.segments.map(\.category.name) == ["System prompt", "Messages", "Autocompact buffer"])
        #expect(b.segments.map(\.range) == [0...10, 10...30, 80...100])
    }

    /// A Claude Code without `kind` is read by the names it has always given free space and the
    /// reserve, and by `isDeferred`.
    @Test func olderHostsAreReadByName() throws {
        let usage: JSONValue = [
            "totalTokens": 10, "rawMaxTokens": 100,
            "categories": [
                ["name": "Messages", "tokens": 10],
                ["name": "Free space", "tokens": 70],
                ["name": "Autocompact buffer", "tokens": 20],
                ["name": "MCP tools", "tokens": 5, "isDeferred": true],
            ],
        ]
        let b = try #require(ContextBreakdown(usage))
        #expect(b.limit == 100)
        #expect(b.categories.map(\.kind) == [.used(0), .free, .buffer, .deferred])
    }

    @Test func noWindowIsNoBreakdown() {
        #expect(ContextBreakdown(["totalTokens": 10, "categories": []]) == nil)
    }
}
