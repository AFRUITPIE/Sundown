import Testing
import TetherKit
import TetherProtocol
@testable import TetherUI

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

    @Test func switchingChatsEndsTheSearch() {
        let w = WindowModel.sample()
        w.find.show(query: "reducer")
        w.open(threadID: "other")
        #expect(!w.find.isPresented)
        #expect(w.find.query.isEmpty)
    }
}
