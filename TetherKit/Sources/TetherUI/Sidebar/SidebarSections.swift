import Foundation

/// Everything the sidebar needs about one chat, and nothing more. A value type so grouping is
/// testable without a `ThreadModel` — and so it can never come to depend on a transcript, which
/// would rebuild the whole sidebar on every streamed delta.
struct SidebarChat: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let cwd: String?
    /// Milliseconds since the epoch, as the server reports it. Nil for a chat that exists only in
    /// this app so far (no first message on disk yet); it is the newest thing there is.
    let updatedAt: Double?
    /// Pinned in this app. An archived chat keeps its pin, but leaves Pinned until it's unarchived.
    var isPinned = false
    var isArchived = false
    /// Waiting on a permission, a question, a plan or a form: the Activity sidebar's Needs You.
    var needsYou = false
}

/// One `Section` of the sidebar list.
struct SidebarSection: Identifiable, Equatable {
    let id: String
    let title: String
    /// The full path behind a directory section's short name; nil when the title says it all.
    let help: String?
    let chats: [SidebarChat]
    /// The folder a directory section lists, for its header's actions; nil for every other section.
    var folder: String? = nil

    static let pinnedID = "pinned"
    static let needsYouID = "needs-you"
}

/// The date buckets, in the order they are shown.
private enum DateBucket: CaseIterable {
    case today, yesterday, previous7, previous30, older

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7: return "Previous 7 Days"
        case .previous30: return "Previous 30 Days"
        case .older: return "Older"
        }
    }

    /// Whole days between the chat's day and today.
    static func forDays(_ days: Int) -> DateBucket {
        switch days {
        case ..<1: return .today   // a clock a little ahead of ours still reads as today
        case 1: return .yesterday
        case 2..<7: return .previous7
        case 7..<30: return .previous30
        default: return .older
        }
    }
}

/// Groups a host's chats for the sidebar. Pure — same inputs, same sections. `now` and `calendar`
/// are parameters so the date buckets can be tested at their boundaries.
///
/// Chats: Pinned on top, then the rest by `grouping`. Activity: Needs You on top, then every other
/// chat by day; `grouping` doesn't apply, and a pin is only a mark on the row. Either way a chat is
/// listed once: the sidebar's outline list traps on two rows with one id.
///
/// Search runs before grouping, so a section only exists if something in it matched.
func sidebarSections(
    chats: [SidebarChat],
    grouping: SidebarGrouping,
    style: Appearance.SidebarStyle = .chats,
    search: String = "",
    now: Date = .now,
    calendar: Calendar = .current
) -> [SidebarSection] {
    let matches = matching(chats, search: search)
    // `sorted(by:)` is not stable, and several chats can share a timestamp (or have none), so the
    // incoming order breaks ties. Otherwise equal rows could swap places between two body passes.
    let ordered = matches.enumerated().sorted { a, b in
        let l = a.element.sortDate(now: now), r = b.element.sortDate(now: now)
        return l == r ? a.offset < b.offset : l > r
    }.map(\.element)

    switch style {
    case .chats:
        let pinned = ordered.filter { $0.isPinned && !$0.isArchived }
        let rest = pinned.isEmpty ? ordered : ordered.filter { !($0.isPinned && !$0.isArchived) }
        let top = pinned.isEmpty ? [] : [SidebarSection(id: SidebarSection.pinnedID, title: "Pinned", help: nil, chats: pinned)]
        switch grouping {
        case .date: return top + byDate(rest, now: now, calendar: calendar)
        case .directory: return top + byDirectory(rest)
        }
    case .activity:
        let waiting = ordered.filter(\.needsYou)
        let rest = waiting.isEmpty ? ordered : ordered.filter { !$0.needsYou }
        let top = waiting.isEmpty ? [] : [SidebarSection(id: SidebarSection.needsYouID, title: "Needs You", help: nil, chats: waiting)]
        return top + byDay(rest, now: now, calendar: calendar)
    }
}

private func matching(_ chats: [SidebarChat], search: String) -> [SidebarChat] {
    let query = search.trimmingCharacters(in: .whitespaces)
    // Deduplicated even with no query: two rows sharing an id trap the sidebar's outline list,
    // and a chat can briefly be both live and listed while a reconnect reloads the catalog.
    var seen = Set<String>()
    return chats.filter { chat in
        guard seen.insert(chat.id).inserted else { return false }
        guard !query.isEmpty else { return true }
        return chat.title.localizedCaseInsensitiveContains(query)
            || (chat.cwd ?? "").localizedCaseInsensitiveContains(query)
    }
}

private func byDate(_ ordered: [SidebarChat], now: Date, calendar: Calendar) -> [SidebarSection] {
    let today = calendar.startOfDay(for: now)
    var grouped: [DateBucket: [SidebarChat]] = [:]
    for chat in ordered {
        let day = calendar.startOfDay(for: chat.sortDate(now: now))
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        grouped[DateBucket.forDays(days), default: []].append(chat)
    }
    return DateBucket.allCases.compactMap { bucket in
        guard let chats = grouped[bucket] else { return nil }
        return SidebarSection(id: bucket.title, title: bucket.title, help: nil, chats: chats)
    }
}

private func byDirectory(_ ordered: [SidebarChat]) -> [SidebarSection] {
    // `ordered` is most-recent-first, so first appearance orders the sections the same way.
    var order: [String?] = []
    var grouped: [String?: [SidebarChat]] = [:]
    for chat in ordered {
        if grouped[chat.cwd] == nil { order.append(chat.cwd) }
        grouped[chat.cwd, default: []].append(chat)
    }
    return order.map { cwd in
        // Keyed on the whole path: two projects can share a last component.
        SidebarSection(id: cwd.map { "dir:\($0)" } ?? "dir:none",
                       title: cwd?.lastPathComponent ?? "No Folder",
                       help: cwd?.abbreviatingHome,
                       chats: grouped[cwd] ?? [],
                       folder: cwd)
    }
}

/// One section per calendar day, newest first, as Mail dates a message: Today, Yesterday, the
/// weekday for the rest of the week, then the date.
private func byDay(_ ordered: [SidebarChat], now: Date, calendar: Calendar) -> [SidebarSection] {
    let today = calendar.startOfDay(for: now)
    var order: [Date] = []
    var grouped: [Date: [SidebarChat]] = [:]
    for chat in ordered {
        // A clock a little ahead of ours still reads as today.
        let day = min(calendar.startOfDay(for: chat.sortDate(now: now)), today)
        if grouped[day] == nil { order.append(day) }
        grouped[day, default: []].append(chat)
    }
    return order.map { day in
        SidebarSection(id: "day:\(Int(day.timeIntervalSince1970))", title: dayTitle(day, today: today, calendar: calendar),
                       help: nil, chats: grouped[day] ?? [])
    }
}

private func dayTitle(_ day: Date, today: Date, calendar: Calendar) -> String {
    let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    switch days {
    case ..<1: return "Today"
    case 1: return "Yesterday"
    case 2..<7: return day.formatted(style.weekday(.wide))
    default:
        let thisYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        return day.formatted(thisYear ? style.month(.wide).day() : style.month(.wide).day().year())
    }
}

extension SidebarChat {
    /// A chat the server has never written down was started here a moment ago.
    fileprivate func sortDate(now: Date) -> Date {
        updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
    }
}
