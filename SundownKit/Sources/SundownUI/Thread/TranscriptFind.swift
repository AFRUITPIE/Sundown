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

    /// Recomputes the matches over `rows`, keeping the current one if it still matches.
    /// `workflowNames` are the names the chat's workflow rows show (`ThreadModel.workflowNames`).
    func update(rows: [TranscriptRow], workflowNames: [String: String] = [:]) {
        apply(Self.search(rows[...], query: query, workflowNames: workflowNames))
    }

    /// `update(rows:)` a moment after the query or the rows last changed, searching off the main
    /// actor: typing in a long chat searched the whole transcript on the main thread at every
    /// keystroke. Cancelled by the next change.
    func search(rows: [TranscriptRow], workflowNames: [String: String] = [:]) async {
        try? await Task.sleep(for: .milliseconds(100))
        let query = query
        guard !Task.isCancelled, let found = await Self.searchOffMain(rows, query: query, workflowNames: workflowNames),
              !Task.isCancelled, query == self.query else { return }
        apply(found)
    }

    /// The ids of the rows that hold `query`, in order.
    nonisolated static func search(_ rows: ArraySlice<TranscriptRow>, query: String,
                                   workflowNames: [String: String] = [:]) -> [String] {
        rows.compactMap { $0.matches(query, workflowNames: workflowNames) ? $0.id : nil }
    }

    /// Nil when cancelled part of the way.
    @concurrent
    nonisolated static func searchOffMain(_ rows: [TranscriptRow], query: String,
                                          workflowNames: [String: String] = [:]) async -> [String]? {
        var found: [String] = []
        for chunk in stride(from: 0, to: rows.count, by: 64) {
            guard !Task.isCancelled else { return nil }
            found += search(rows[chunk..<min(chunk + 64, rows.count)], query: query, workflowNames: workflowNames)
        }
        return found
    }

    private func apply(_ found: [String]) {
        let previous = current
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
    /// The names the chat's workflow rows show, which Find matches them by.
    var workflowNames: [String: String] = [:]
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
        .onAppear { find.update(rows: rows, workflowNames: workflowNames) }
        .task(id: SearchKey(query: find.query, rows: rows.count)) { await find.search(rows: rows, workflowNames: workflowNames) }
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
            FindBar(find: find, rows: thread.rows(appearance.toolCalls.folding), workflowNames: thread.workflowNames)
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
