import SwiftUI
import TetherKit

/// When the prompt below it was sent, centered above it where the chat picks up after a break, as
/// Messages marks one: "Today 2:14 PM", "Yesterday 9:05 PM", "Wednesday 10:12 AM", or the date.
/// The day in the heavier weight, the time beside it.
struct DateSeparatorView: View {
    /// Milliseconds since 1970.
    let ms: Double

    var body: some View {
        let label = TranscriptDate.label(for: Date(timeIntervalSince1970: ms / 1000))
        Text("\(Text(label.day).fontWeight(.semibold)) \(label.time)")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            // Nearer the prompt it dates than the reply above it.
            .padding(.top, 8)
            // A heading, so VoiceOver's rotor moves through the chat by when it happened.
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("transcript.date")
    }
}

/// The words a date separator says, in the reader's locale. Pure, so it's tested with a fixed now.
enum TranscriptDate {
    struct Label: Equatable {
        /// "Today", "Yesterday", a weekday in the last week, or the date.
        let day: String
        let time: String
        var text: String { "\(day) \(time)" }
    }

    static func label(for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> Label {
        var calendar = calendar
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch daysAgo {
        case 0, 1:
            return Label(day: relativeDay(-daysAgo, calendar: calendar, locale: locale), time: time)
        case 2..<7:
            return Label(day: date.formatted(style.weekday(.wide)), time: time)
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let format = sameYear ? style.weekday(.abbreviated).month(.abbreviated).day() : style.month(.abbreviated).day().year()
            return Label(day: date.formatted(format), time: time)
        }
    }

    /// "Today" or "Yesterday", capitalized as the locale starts a sentence.
    private static func relativeDay(_ offset: Int, calendar: Calendar, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(from: DateComponents(day: offset))
    }
}

#if DEBUG
/// A chat picked up over more than a week: a date above each prompt after a day change or a break
/// of more than an hour, none above a follow-up sent minutes after the reply.
#Preview("Transcript with dates") {
    TranscriptView(thread: .sampleDatedChat())
        .frame(width: 760, height: 900)
}

#Preview("Date separators") {
    let now = Date.now
    VStack(spacing: 14) {
        ForEach([0.0, 1, 3, 20, 400], id: \.self) { days in
            DateSeparatorView(ms: (now.timeIntervalSince1970 - days * 86_400 - 3_600) * 1000)
        }
    }
    .padding(20)
    .frame(width: 420)
}
#endif
