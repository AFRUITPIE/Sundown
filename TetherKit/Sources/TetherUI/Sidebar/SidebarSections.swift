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
}

/// One `Section` of the sidebar list.
struct SidebarSection: Identifiable, Equatable {
    let id: String
    let title: String
    /// The full path behind a directory section's short name; nil when the title says it all.
    let help: String?
    let chats: [SidebarChat]
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
/// Search runs before grouping, so a section only exists if something in it matched.
func sidebarSections(
    chats: [SidebarChat],
    grouping: SidebarGrouping,
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

    switch grouping {
    case .date: return byDate(ordered, now: now, calendar: calendar)
    case .directory: return byDirectory(ordered)
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
                       chats: grouped[cwd] ?? [])
    }
}

extension SidebarChat {
    /// A chat the server has never written down was started here a moment ago.
    fileprivate func sortDate(now: Date) -> Date {
        updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
    }
}
