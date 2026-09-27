import SwiftUI
import TetherKit

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

    public var current: String? { matches.indices.contains(index) ? matches[index] : nil }

    /// Recomputes the matches over `rows`, keeping the current one if it still matches.
    func update(rows: [TranscriptRow]) {
        let previous = current
        matches = rows.filter { $0.matches(query) }.map(\.id)
        if let previous, let i = matches.firstIndex(of: previous) {
            index = i
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
    }

    public func previous() {
        guard !matches.isEmpty else { return }
        index = (index - 1 + matches.count) % matches.count
        step += 1
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
                    .help("Show the previous match")
                Button("Next", systemImage: "chevron.right") { find.next() }
                    .help("Show the next match")
            }
            .labelStyle(.iconOnly)
            .disabled(find.matches.isEmpty)
            Spacer(minLength: 0)
            Button("Done") { find.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { find.update(rows: rows) }
        // Typing goes straight into the field: ⌘F is how people start a search. Deferred until the
        // bar is in the window, which it isn't yet when it appears.
        .task(id: find.focusRequest) {
            try? await Task.sleep(for: .milliseconds(100))
            focused = true
        }
        .onChange(of: find.query) { find.update(rows: rows) }
        .onChange(of: rows.count) { find.update(rows: rows) }
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
            FindBar(find: find, rows: thread.rows(grouped: appearance.toolCalls == .summarized))
        }
    }
}
