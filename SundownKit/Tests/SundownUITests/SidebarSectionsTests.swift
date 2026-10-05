import Foundation
import Testing
@testable import SundownUI

/// `sidebarSections` is pure, so every case below pins `now` and a UTC calendar and asserts on
/// the sections it returns — no view, no `ThreadModel`, no clock.
@Suite
struct SidebarSectionsTests {
    /// Afternoon, so a chat a few hours old is still "today".
    private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func chat(_ id: String, _ title: String = "Chat", cwd: String? = "/Users/hayden/Code/tether-app",
                      daysAgo: Double = 0, hoursAgo: Double = 0,
                      pinned: Bool = false, archived: Bool = false) -> SidebarChat {
        SidebarChat(id: id, title: title, cwd: cwd,
                    updatedAt: (now.timeIntervalSince1970 - daysAgo * 86_400 - hoursAgo * 3_600) * 1000,
                    isPinned: pinned, isArchived: archived)
    }

    private func sections(_ chats: [SidebarChat], _ grouping: SidebarGrouping = .date,
                          search: String = "") -> [SidebarSection] {
        sidebarSections(chats: chats, grouping: grouping, search: search, now: now, calendar: calendar)
    }

    // MARK: date buckets

    @Test func datesLandInTheirBucketAtEveryBoundary() {
        let result = sections([
            chat("today", hoursAgo: 2),
            chat("yesterday", daysAgo: 1),
            chat("two-days", daysAgo: 2),
            chat("six-days", daysAgo: 6),
            chat("seven-days", daysAgo: 7),
            chat("twenty-nine-days", daysAgo: 29),
            chat("thirty-days", daysAgo: 30),
        ])

        #expect(result.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"])
        #expect(result[0].chats.map(\.id) == ["today"])
        #expect(result[1].chats.map(\.id) == ["yesterday"])
        #expect(result[2].chats.map(\.id) == ["two-days", "six-days"])
        #expect(result[3].chats.map(\.id) == ["seven-days", "twenty-nine-days"])
        #expect(result[4].chats.map(\.id) == ["thirty-days"])
    }

    @Test func aBucketWithNothingInItIsNotShown() {
        let result = sections([chat("a", hoursAgo: 1), chat("b", daysAgo: 40)])

        #expect(result.map(\.title) == ["Today", "Older"])
    }

    @Test func yesterdayIsTheCalendarDayBeforeNotTwentyFourHours() {
        // 16 hours before 14:13 UTC is 22:13 the previous day: yesterday, not "less than a day".
        let result = sections([chat("late-last-night", hoursAgo: 16)])

        #expect(result.map(\.title) == ["Yesterday"])
    }

    @Test func aChatWithNoTimestampIsBrandNew() {
        let fresh = SidebarChat(id: "fresh", title: "New Chat", cwd: nil, updatedAt: nil)

        let result = sections([chat("old", daysAgo: 3), fresh])

        #expect(result.map(\.title) == ["Today", "Previous 7 Days"])
        #expect(result[0].chats.map(\.id) == ["fresh"])
    }

    @Test func rowsWithinASectionAreMostRecentFirst() {
        let result = sections([chat("older", hoursAgo: 5), chat("newer", hoursAgo: 1), chat("middle", hoursAgo: 3)])

        #expect(result[0].chats.map(\.id) == ["newer", "middle", "older"])
    }

    // MARK: directories

    @Test func directoriesBecomeSectionsOrderedByTheirMostRecentChat() {
        let result = sections([
            chat("app-old", cwd: "/Users/hayden/Code/tether-app", daysAgo: 4),
            chat("server-new", cwd: "/Users/hayden/Code/tether-server", hoursAgo: 1),
            chat("app-new", cwd: "/Users/hayden/Code/tether-app", daysAgo: 2),
        ], .directory)

        #expect(result.map(\.title) == ["tether-server", "tether-app"])
        #expect(result[1].chats.map(\.id) == ["app-new", "app-old"])
    }

    @Test func twoFoldersWithTheSameNameStayTwoSections() {
        let result = sections([
            chat("current", cwd: "/Users/hayden/Code/tether-app", hoursAgo: 1),
            chat("archived", cwd: "/Users/hayden/Developer/archive/tether-app", daysAgo: 5),
        ], .directory)

        #expect(result.count == 2)
        #expect(result.map(\.title) == ["tether-app", "tether-app"])
        #expect(Set(result.map(\.id)).count == 2)
        #expect(result.map(\.help) == ["/Users/hayden/Code/tether-app", "/Users/hayden/Developer/archive/tether-app"])
    }

    @Test func chatsWithoutAFolderGetTheirOwnSection() {
        let result = sections([
            chat("none", cwd: nil, hoursAgo: 1),
            chat("some", cwd: "/Users/hayden/Code/tether-app", daysAgo: 2),
        ], .directory)

        #expect(result.map(\.title) == ["No Directory", "tether-app"])
        #expect(result[0].help == nil)
    }

    // MARK: search

    @Test func searchMatchesTitleAndFolderIgnoringCase() {
        let chats = [
            chat("by-title", "Rebuild the Sidebar", cwd: "/Users/hayden/Code/tether-app", hoursAgo: 1),
            chat("by-folder", "Unrelated", cwd: "/Users/hayden/Code/tether-server", daysAgo: 2),
            chat("no-match", "Unrelated", cwd: "/Users/hayden/Code/other", daysAgo: 3),
        ]

        #expect(sections(chats, search: "sidebar").flatMap { $0.chats.map(\.id) } == ["by-title"])
        #expect(sections(chats, search: "SERVER").flatMap { $0.chats.map(\.id) } == ["by-folder"])
        #expect(sections(chats, search: "tether").flatMap { $0.chats.map(\.id) } == ["by-title", "by-folder"])
    }

    @Test func searchRunsBeforeGroupingSoEmptySectionsNeverAppear() {
        let result = sections([
            chat("kept", "Sidebar", cwd: "/Users/hayden/Code/tether-app", hoursAgo: 1),
            chat("dropped", "Inspector", cwd: "/Users/hayden/Code/tether-app", daysAgo: 40),
        ], search: "sidebar")

        #expect(result.map(\.title) == ["Today"])
    }

    @Test func aSearchThatMatchesNothingHasNoSections() {
        #expect(sections([chat("a", "Sidebar")], search: "kubernetes").isEmpty)
    }

    // MARK: identity

    @Test func aChatListedTwiceAppearsOnce() {
        let result = sections([chat("same", "First", hoursAgo: 1), chat("same", "Second", daysAgo: 3)])

        #expect(result.flatMap { $0.chats.map(\.id) } == ["same"])
        #expect(result[0].chats[0].title == "First")
    }

    // MARK: pinned

    @Test func pinnedChatsComeFirstMostRecentFirstAndAreNotRepeated() {
        let result = sections([
            chat("old-pin", daysAgo: 40, pinned: true),
            chat("today", hoursAgo: 1),
            chat("new-pin", hoursAgo: 2, pinned: true),
            chat("yesterday", daysAgo: 1),
        ])

        #expect(result.map(\.title) == ["Pinned", "Today", "Yesterday"])
        #expect(result[0].id == SidebarSection.pinnedID)
        #expect(result[0].chats.map(\.id) == ["new-pin", "old-pin"])
        #expect(result[1].chats.map(\.id) == ["today"])
        // Every chat once: the outline list traps on two rows with one id.
        #expect(result.flatMap { $0.chats.map(\.id) }.count == 4)
    }

    @Test func pinnedStaysOnTopWhenGroupedByFolder() {
        let result = sections([
            chat("server", cwd: "/Users/hayden/Code/tether-server", hoursAgo: 1),
            chat("pinned-app", cwd: "/Users/hayden/Code/tether-app", daysAgo: 3, pinned: true),
            chat("app", cwd: "/Users/hayden/Code/tether-app", daysAgo: 5),
        ], .directory)

        #expect(result.map(\.title) == ["Pinned", "tether-server", "tether-app"])
        #expect(result[0].folder == nil)
        #expect(result[2].chats.map(\.id) == ["app"])
    }

    @Test func aFolderWhollyPinnedHasNoSectionOfItsOwn() {
        let result = sections([
            chat("pinned-app", cwd: "/Users/hayden/Code/tether-app", hoursAgo: 1, pinned: true),
            chat("server", cwd: "/Users/hayden/Code/tether-server", daysAgo: 2),
        ], .directory)

        #expect(result.map(\.title) == ["Pinned", "tether-server"])
    }

    @Test func anArchivedChatLeavesPinnedWhileArchived() {
        let result = sections([
            chat("archived-pin", daysAgo: 1, pinned: true, archived: true),
            chat("pin", hoursAgo: 3, pinned: true),
        ])

        #expect(result.map(\.title) == ["Pinned", "Yesterday"])
        #expect(result[0].chats.map(\.id) == ["pin"])
        #expect(result[1].chats.map(\.id) == ["archived-pin"])
    }

    @Test func searchAppliesToPinnedToo() {
        let result = sections([
            chat("pin", "Unrelated", hoursAgo: 1, pinned: true),
            chat("match", "Sidebar", daysAgo: 2),
        ], search: "sidebar")

        #expect(result.map(\.title) == ["Previous 7 Days"])
    }

    // MARK: folders

    @Test func folderSectionsCarryTheirFolderForTheHeadersActions() {
        let result = sections([
            chat("app", cwd: "/Users/hayden/Code/tether-app", hoursAgo: 1),
            chat("none", cwd: nil, daysAgo: 2),
        ], .directory)

        #expect(result.map(\.folder) == ["/Users/hayden/Code/tether-app", nil])
        #expect(sections([chat("app", hoursAgo: 1)]).allSatisfy { $0.folder == nil })
    }

    // MARK: nothing to group

    @Test func noChatsMeansNoSections() {
        #expect(sections([]).isEmpty)
        #expect(sections([], .directory).isEmpty)
    }
}
