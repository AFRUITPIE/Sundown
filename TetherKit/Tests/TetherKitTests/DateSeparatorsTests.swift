import Foundation
import Testing
import TetherProtocol
@testable import TetherKit

@Suite
struct DateSeparatorsTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// 2026-09-23 10:00 in Los Angeles, plus `hours`, in ms.
    private func at(hours: Double) -> Double {
        (1_790_182_800 + hours * 3_600) * 1000
    }

    @Test func theFirstPromptShownGetsOne() {
        #expect(DateSeparators.needsSeparator(at: at(hours: 0), previousPrompt: nil, previousItem: nil, calendar: calendar))
    }

    @Test func aPromptOnAnotherDayGetsOne() {
        // 23:50 then 00:10: twenty minutes apart, but the day changed.
        #expect(DateSeparators.needsSeparator(at: at(hours: 14.2), previousPrompt: at(hours: 13.8), previousItem: at(hours: 13.9),
                                              calendar: calendar))
    }

    /// More than an hour after the last thing in the chat, not after the prompt before.
    @Test func aPromptAfterAnHoursBreakGetsOne() {
        #expect(DateSeparators.needsSeparator(at: at(hours: 3), previousPrompt: at(hours: 0), previousItem: at(hours: 1.9),
                                              calendar: calendar))
        #expect(!DateSeparators.needsSeparator(at: at(hours: 3), previousPrompt: at(hours: 0), previousItem: at(hours: 2.5),
                                               calendar: calendar))
    }

    @Test func aFollowUpWithinTheHourGetsNone() {
        #expect(!DateSeparators.needsSeparator(at: at(hours: 0.5), previousPrompt: at(hours: 0), previousItem: at(hours: 0.1),
                                               calendar: calendar))
    }

    @Test func promptsAreFoundAmongTheChatsItems() {
        func prompt(_ id: String, _ hours: Double) -> Item {
            .userMessage(.init(id: id, createdAt: at(hours: hours), content: [.text(.init(text: "go"))]))
        }
        func reply(_ id: String, _ hours: Double) -> Item {
            .agentMessage(.init(id: id, createdAt: at(hours: hours), text: "done"))
        }
        let untimed = Item.userMessage(.init(id: "untimed", createdAt: 0, content: [.text(.init(text: "?"))]))
        let items = [prompt("p1", 0), reply("m1", 0.1), prompt("p2", 0.5), reply("m2", 0.6), untimed,
                     prompt("p3", 2), reply("m3", 2.1), prompt("p4", 24)]
        #expect(DateSeparators.prompts(in: items, calendar: calendar) == ["p1": at(hours: 0), "p3": at(hours: 2), "p4": at(hours: 24)])
    }
}
