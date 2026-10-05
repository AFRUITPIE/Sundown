import Testing
import SundownKit
import TetherProtocol
@testable import SundownUI

@MainActor
@Suite
struct TranscriptFindTests {
    private func rows() -> [TranscriptRow] {
        [
            .item(.userMessage(.init(id: "u1", createdAt: 0, content: [.text(.init(text: "Why does the reducer drop deltas?"))]))),
            .item(.agentMessage(.init(id: "a1", createdAt: 1, text: "The **reducer** batches them per frame."))),
            .toolGroup([.init(id: "t1", createdAt: 2, name: "Bash", kind: .bash,
                              input: ["command": "rg -n Reducer Sources"], status: .completed, outputText: "ThreadModel.swift")]),
            .item(.agentMessage(.init(id: "a2", createdAt: 3, text: "Nothing else to report."))),
        ]
    }

    @Test func matchesTextInputAndOutputIgnoringCase() {
        let r = rows()
        #expect(r.filter { $0.matches("reducer") }.map(\.id) == ["u1", "a1", "group-t1"])
        #expect(r.filter { $0.matches("threadmodel") }.map(\.id) == ["group-t1"])
        #expect(!r[0].matches(""))
    }

    @Test func aSearchStartsAtTheLatestMatchAndWraps() {
        let find = TranscriptFind()
        find.query = "reducer"
        find.update(rows: rows())
        #expect(find.current == "group-t1")

        find.next()
        #expect(find.current == "u1")
        find.previous()
        find.previous()
        #expect(find.current == "a1")
    }

    @Test func theCurrentMatchSurvivesNewRows() {
        let find = TranscriptFind()
        find.query = "reducer"
        find.update(rows: rows())
        find.previous()
        #expect(find.current == "a1")

        var more = rows()
        more.append(.item(.agentMessage(.init(id: "a3", createdAt: 4, text: "Another reducer note."))))
        find.update(rows: more)
        #expect(find.current == "a1")
        #expect(find.matches.count == 4)
    }

    /// Find searches the rows the transcript shows: with Worked For, a match inside a finished turn's
    /// folded work is the fold row, which the transcript can scroll to and open.
    @Test func aMatchInsideWorkedForIsItsFoldRow() {
        let thread = ThreadModel.sample(items: [
            .sampleUserMessage("Why does the reducer drop deltas?", secondsAgo: 30),
            .sampleToolCall(name: "Bash", kind: .bash, input: ["command": "rg -n coalesce Sources"], status: .completed,
                            outputText: "HostConnection.swift", secondsAgo: 20),
            .sampleAgentMessage("They're coalesced per frame.", secondsAgo: 10),
        ])
        let shown = thread.rows(Appearance.ToolCallDisplay.workedFor.folding)
        let find = TranscriptFind()
        find.query = "coalesce"
        find.update(rows: shown)
        let fold = shown.first { if case .turnWork = $0 { true } else { false } }
        #expect(fold != nil)
        #expect(find.matches == [fold?.id, shown.last?.id].compactMap { $0 })
        #expect(Set(find.matches).isSubset(of: shown.map(\.id)))
    }

    /// Find keeps each row's text and result between searches; whatever changes — the query, rows
    /// added, a row's contents — the matches are what searching every row afresh finds.
    @Test func keptResultsMatchSearchingAfresh() {
        let find = TranscriptFind()
        var shown = rows()
        func check(_ query: String, _ note: Comment) {
            find.query = query
            find.update(rows: shown)
            #expect(find.matches == shown.filter { $0.matches(query) }.map(\.id), note)
        }
        check("reducer", "first search")
        check("red", "narrower query")
        check("", "empty query")
        check("RÉDUCER", "case and diacritics")
        shown.append(.item(.agentMessage(.init(id: "a3", createdAt: 4, text: "The reducer again."))))
        check("reducer", "a row added")
        // A row that changes in place, as a reply does while it streams, is searched again.
        shown[3] = .item(.agentMessage(.init(id: "a2", createdAt: 3, text: "Nothing else about the reducer.")))
        check("reducer", "a row changed")
        shown[1] = .item(.agentMessage(.init(id: "a1", createdAt: 1, text: "Batched per frame.")))
        check("reducer", "a match gone")
        shown.removeFirst()
        check("reducer", "a row gone")
        check("threadmodel", "another query over kept text")
    }

    /// Typing searches a moment later, off the main actor, and finds what searching at once finds.
    @Test func searchingOffTheMainActorFindsTheSame() async {
        let find = TranscriptFind()
        find.query = "reducer"
        await find.search(rows: rows())
        #expect(find.matches == ["u1", "a1", "group-t1"])
        #expect(find.current == "group-t1")
        // A search the next keystroke replaced changes nothing.
        find.query = "frame"
        let replaced = Task { await find.search(rows: rows()) }
        replaced.cancel()
        await replaced.value
        #expect(find.matches == ["u1", "a1", "group-t1"])
    }

    @Test func switchingChatsEndsTheSearch() {
        let w = WindowModel.sample()
        w.find.show(query: "reducer")
        w.open(threadID: "other")
        #expect(!w.find.isPresented)
        #expect(w.find.query.isEmpty)
    }
}
