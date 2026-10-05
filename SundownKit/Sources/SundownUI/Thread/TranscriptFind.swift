import SwiftUI
import SundownKit

/// Find in Chat, for one window: what's being looked for, the rows that match it, and which of them
/// is current. The bar edits `query`; the transcript scrolls to `current` and highlights `matches`.
@MainActor
@Observable
public final class TranscriptFind {
    /// Whether the find bar is showing.
    public var isPresented = false
    public var query = ""
    /// The matching rows' ids, in transcript order.
    public private(set) var matches: [String] = []
    public private(set) var index = 0
    /// Bumped by Next and Previous, so the transcript scrolls even when the match doesn't change.
    public private(set) var step = 0
    /// Bumped by Next and Previous alone, not by a new search, for what's announced.
    public private(set) var moves = 0

    public var current: String? { matches.indices.contains(index) ? matches[index] : nil }

    /// Each row searched while the bar is open, by id: its search text, and whether it held the query
    /// it was last searched for. A row that hasn't changed isn't made into text again, nor searched
    /// again for the same query, so a new row or a keystroke searches only what it needs to.
    @ObservationIgnored private var searched: [String: Searched] = [:]

    private struct Searched {
        /// The row as it was searched, to tell whether it has changed since.
        let row: TranscriptRow
        let text: String
        let query: String
        let matches: Bool
    }

    /// A row to search, with its text when that's known already.
    struct Pending: Sendable {
        let row: TranscriptRow
        let text: String?
    }

    struct Result: Sendable {
        let row: TranscriptRow
        let text: String
        let matches: Bool
    }

    /// Recomputes the matches over `rows`, keeping the current one if it still matches.
    func update(rows: [TranscriptRow]) {
        let query = query
        apply(Self.search(pending(rows, query: query), query: query), rows: rows, query: query)
    }

    /// `update(rows:)` a moment after the query or the rows last changed, searching off the main
    /// actor: typing in a long chat searched the whole transcript on the main thread at every
    /// keystroke. Cancelled by the next change.
    func search(rows: [TranscriptRow]) async {
        try? await Task.sleep(for: .milliseconds(100))
        let query = query
        guard !Task.isCancelled,
              let results = await Self.searchOffMain(pending(rows, query: query), query: query),
              !Task.isCancelled, query == self.query else { return }
        apply(results, rows: rows, query: query)
    }

    /// The rows whose text isn't known, or that haven't been searched for `query`.
    private func pending(_ rows: [TranscriptRow], query: String) -> [Pending] {
        guard !query.isEmpty else { return [] }
        return rows.compactMap { row in
            guard let known = searched[row.id], known.row == row else { return Pending(row: row, text: nil) }
            return known.query == query ? nil : Pending(row: row, text: known.text)
        }
    }

    nonisolated static func search(_ pending: [Pending], query: String) -> [Result] {
        pending.map { item in
            let text = item.text ?? item.row.searchText
            return Result(row: item.row, text: text, matches: TranscriptRow.text(text, matches: query))
        }
    }

    /// Nil when cancelled part of the way.
    @concurrent
    nonisolated static func searchOffMain(_ pending: [Pending], query: String) async -> [Result]? {
        var results: [Result] = []
        results.reserveCapacity(pending.count)
        for chunk in stride(from: 0, to: pending.count, by: 64) {
            guard !Task.isCancelled else { return nil }
            results += search(Array(pending[chunk..<min(chunk + 64, pending.count)]), query: query)
        }
        return results
    }

    private func apply(_ results: [Result], rows: [TranscriptRow], query: String) {
        for result in results {
            searched[result.row.id] = Searched(row: result.row, text: result.text, query: query, matches: result.matches)
        }
        let previous = current
        let found = rows.compactMap { row in
            searched[row.id].flatMap { $0.query == query && $0.matches ? row.id : nil }
        }
        // Set only when changed: every set redraws what reads it.
        if found != matches { matches = found }
        if let previous, let i = matches.firstIndex(of: previous) {
            if index != i { index = i }
        } else {
            // A new search starts from the latest match, nearest where the reader usually is.
            index = max(matches.count - 1, 0)
            step += 1
        }
    }

    public func next() {
        guard !matches.isEmpty else { return }
        index = (index + 1) % matches.count
        step += 1
        moves += 1
    }

    public func previous() {
        guard !matches.isEmpty else { return }
        index = (index - 1 + matches.count) % matches.count
        step += 1
        moves += 1
    }

    /// Bumped by Find… so the field takes the keyboard again when the bar is already open.
    public private(set) var focusRequest = 0

    /// Edit ▸ Find….
    public func show(query: String? = nil) {
        if let query { self.query = query }
        isPresented = true
        focusRequest += 1
    }

    public func dismiss() {
        isPresented = false
        query = ""
        matches = []
        index = 0
        searched = [:]
    }
}

extension EnvironmentValues {
    /// The window's Find in Chat, for the find bar, the transcript and its rows.
    @Entry var transcriptFind: TranscriptFind?
}

/// The find bar over the transcript: a search field, where the current match is, Previous and Next,
/// and Done — the layout macOS text views use.
struct FindBar: View {
    @Bindable var find: TranscriptFind
    let rows: [TranscriptRow]
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in Chat", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { find.next() }
                .accessibilityIdentifier("find.field")
                .frame(maxWidth: 280)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("find.status")
            ControlGroup {
                Button("Previous", systemImage: "chevron.left") { find.previous() }
                    .help("Previous Match")
                Button("Next", systemImage: "chevron.right") { find.next() }
                    .help("Next Match")
            }
            .labelStyle(.iconOnly)
            .disabled(find.matches.isEmpty)
            Spacer(minLength: 0)
            Button("Done") { find.dismiss() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Esc closes the bar from within it; from the message field it's still the field's (it
        // stops a running turn), not the bar's.
        .onExitCommand { find.dismiss() }
        // At once when the bar opens; then a moment after each change, off the main actor.
        .onAppear { find.update(rows: rows) }
        .task(id: SearchKey(query: find.query, rows: rows.count)) { await find.search(rows: rows) }
        // Typing goes straight into the field: ⌘F is how people start a search, even from the
        // message field.
        .defaultFocus($focused, true, priority: .userInitiated)
        .onChange(of: find.focusRequest, initial: true) { focused = true }
        // Where Next and Previous landed, said, since the match moves out of sight of the field.
        .onChange(of: find.moves) { AccessibilityNotification.Announcement(status).post() }
    }

    private struct SearchKey: Equatable {
        let query: String
        let rows: Int
    }

    private var status: String {
        if find.query.isEmpty { return "" }
        if find.matches.isEmpty { return "Not Found" }
        return "\(find.index + 1) of \(find.matches.count)"
    }
}

/// The find bar when Find in Chat is open, and nothing otherwise. Its own view, so only it reads the
/// rows it searches, not the chat around it.
struct FindBarHost: View {
    let thread: ThreadModel
    @Environment(\.transcriptFind) private var find
    @Environment(\.appearance) private var appearance

    var body: some View {
        if let find, find.isPresented {
            FindBar(find: find, rows: thread.rows(appearance.toolCalls.folding))
        }
    }
}

#if DEBUG
/// A search under way: the field, where the current match is among them, and Previous and Next.
#Preview("Find bar") {
    let thread = ThreadModel.sampleWorkChat()
    let find = TranscriptFind()
    find.show(query: "inspector")
    return FindBar(find: find, rows: thread.rows(Appearance().toolCalls.folding))
        .frame(width: 640)
}

#Preview("Find bar (not found)") {
    let find = TranscriptFind()
    find.show(query: "nothing like this")
    return FindBar(find: find, rows: ThreadModel.sampleWorkChat().rows(Appearance().toolCalls.folding))
        .frame(width: 640)
}
#endif
