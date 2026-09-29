import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

/// The long fixture chat pages back to its start, one older page at a time.
@MainActor
@Suite
struct OlderHistoryFixtureTests {
    @Test func olderPagesLoadUntilTheStart() async throws {
        let connection = UITestFixture.connection(performance: true)
        await connection.connect()
        let thread = try #require(connection.chats.first { $0.id == UITestFixture.threadID })
        await connection.open(thread)
        var counts = [thread.items.count]
        var outcomes: [HostConnection.OlderHistoryOutcome] = []
        for _ in 0..<40 where thread.hasMoreHistory {
            outcomes.append(await connection.loadOlderHistory(thread))
            counts.append(thread.items.count)
        }
        #expect(!thread.hasMoreHistory)
        #expect(counts.last == PerformanceTranscript.history.count)
        await connection.disconnect()
    }
}
