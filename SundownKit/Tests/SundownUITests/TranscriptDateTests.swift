import Foundation
import Testing
@testable import SundownUI

@Suite
struct TranscriptDateTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private let english = Locale(identifier: "en_US")

    /// Sunday 2026-09-27 16:00 in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_790_550_000)

    private func label(_ hoursAgo: Double, locale: Locale? = nil) -> String {
        TranscriptDate.label(for: now.addingTimeInterval(-hoursAgo * 3_600), now: now, calendar: calendar,
                             locale: locale ?? english).text
    }

    /// Normalizes the narrow no-break space ICU puts before AM and PM.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func todayAndYesterdayByName() {
        #expect(plain(label(1.75)) == "Today 2:15 PM")
        #expect(plain(label(19)) == "Yesterday 9:00 PM")
    }

    /// Within the last week, the weekday; before that, the date, with the year once it's another.
    @Test func thenTheWeekdayThenTheDate() {
        #expect(plain(label(4 * 24 + 6)) == "Wednesday 10:00 AM")
        #expect(plain(label(10 * 24)) == "Thu, Sep 17 4:00 PM")
        #expect(plain(label(400 * 24)) == "Aug 23, 2025 4:00 PM")
    }

    /// The reader's locale words and orders it.
    @Test func inTheReadersLocale() {
        let french = Locale(identifier: "fr_FR")
        #expect(plain(label(1.75, locale: french)) == "Aujourd’hui 14:15")
        #expect(label(4 * 24 + 6, locale: french).hasPrefix("mercredi"))
    }
}
