import CoreGraphics
import Testing
import SundownKit
import ServerProtocol
@testable import SundownUI

/// The transcript's height index: where rows start, which rows to build for a view, and how far a
/// change above the reader moves them.
@Suite
struct TranscriptHeightIndexTests {
    /// Rows 10, 20, 30, 40 tall, 5 apart: tops 0, 15, 40, 75; total 120.
    private let index = HeightIndex(ids: ["a", "b", "c", "d"], heights: [10, 20, 30, 40], spacing: 5)

    @Test func prefixSums() {
        #expect((0...4).map(index.top) == [0, 15, 40, 75, 120])
        #expect(index.total == 120)
        #expect(index.bottom(1) == 35)
        #expect(index.index(of: "c") == 2)
        #expect(index.index(of: "z") == nil)
        #expect(HeightIndex(spacing: 5).total == 0)
    }

    @Test func rowAtAPoint() {
        #expect(index.row(at: -10) == 0)
        #expect(index.row(at: 0) == 0)
        #expect(index.row(at: 14.9) == 0)
        #expect(index.row(at: 15) == 1)
        #expect(index.row(at: 74) == 2)
        #expect(index.row(at: 500) == 3)
        #expect(HeightIndex(spacing: 5).row(at: 0) == nil)
    }

    @Test func windowRange() {
        // A view of 20…50 meets b and c; 10 more either way reaches a and d.
        #expect(index.rows(from: 20, to: 50) == 1..<3)
        #expect(index.window(for: 20...50, overscan: 10) == 0..<3)
        #expect(index.window(for: 20...50, overscan: 30) == 0..<4)
        // Past either end: clamped.
        #expect(index.rows(from: -100, to: -50) == 0..<0)
        #expect(index.rows(from: 200, to: 300) == 4..<4)
        #expect(index.rows(from: 100, to: 300) == 3..<4)
    }

    @Test func coverage() {
        // Rows a…c built cover a view of 0…30 with 5 to spare, but not with 20.
        #expect(index.covers(0..<3, 0...30, margin: 5))
        #expect(!index.covers(0..<3, 0...30, margin: 50))
        // At the end, the last row reaching it is enough.
        #expect(index.covers(2..<4, 90...120, margin: 50))
        #expect(!index.covers(0..<0, 0...30, margin: 0))
    }

    @Test func settingHeightsMovesWhatFollows() {
        var i = index
        let moved = i.setHeight(25, at: 1)
        #expect(moved == 5)
        #expect((0...4).map(i.top) == [0, 15, 45, 80, 125])
        let both = i.setHeights([(index: 3, height: 10), (index: 0, height: 20)])
        #expect(both == -20)
        #expect((0...4).map(i.top) == [0, 25, 55, 90, 105])
    }

    @Test func anchorIsTheFirstRowBelowTheTop() {
        #expect(index.anchor(at: 20)! == (1, 5))
        // In the spacing after a: b holds the place, 2 above it.
        #expect(index.anchor(at: 13)! == (1, -2))
        #expect(index.anchor(at: 0)! == (0, 0))
    }

    @Test func placeKeptByTheAnchor() {
        // Kept by the anchor: after a change above, its top plus the offset is where the view goes.
        var i = index
        let (row, offset) = i.anchor(at: 50)!
        i.setHeight(110, at: 0)
        #expect(i.top(row) + offset == 150, "\(row) \(offset) \(i.top(row))")
    }

    @Test func liveTurnStartsAtTheLastPrompt() {
        func prompt(_ id: String) -> TranscriptRow { .item(.userMessage(.init(id: id, createdAt: 0, content: [.text(.init(text: id))]))) }
        func reply(_ id: String) -> TranscriptRow { .item(.agentMessage(.init(id: id, createdAt: 0, text: id))) }
        #expect(TranscriptSplit.liveStart([]) == 0)
        #expect(TranscriptSplit.liveStart([reply("r0")]) == 0)
        // No prompt among them: all but the last few are history.
        let replies = (0..<20).map { reply("r\($0)") }
        #expect(TranscriptSplit.liveStart(replies) == 20 - TranscriptSplit.liveWithoutPrompt)
        #expect(TranscriptSplit.liveStart([prompt("p1"), reply("r1"), prompt("p2"), reply("r2")]) == 2)
        // The date above it goes with it.
        let dated: [TranscriptRow] = [prompt("p1"), reply("r1"), .dateSeparator(promptID: "p2", ms: 0), prompt("p2")]
        #expect(TranscriptSplit.liveStart(dated) == 2)
    }
}
