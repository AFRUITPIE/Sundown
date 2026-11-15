import CoreGraphics
import SundownKit

/// Every settled row's height at the transcript's current width, and where each row starts: the
/// transcript's virtualization is arithmetic on these, never an estimate. Each row's slot is its
/// height and the spacing after it.
struct HeightIndex {
    let spacing: CGFloat
    private(set) var ids: [String] = []
    private(set) var heights: [CGFloat] = []
    /// `tops[i]` is row i's top; `tops[count]` the total.
    private(set) var tops: [CGFloat] = [0]
    private var positions: [String: Int] = [:]

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    init(ids: [String], heights: [CGFloat], spacing: CGFloat) {
        precondition(ids.count == heights.count)
        self.spacing = spacing
        self.ids = ids
        self.heights = heights
        positions.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { positions[id] = i }
        tops = [0]
        tops.reserveCapacity(ids.count + 1)
        for h in heights { tops.append(tops[tops.count - 1] + h + spacing) }
    }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    var total: CGFloat { tops[count] }

    func index(of id: String) -> Int? { positions[id] }
    func top(_ i: Int) -> CGFloat { tops[min(max(i, 0), count)] }
    func height(_ i: Int) -> CGFloat { heights[i] }
    func bottom(_ i: Int) -> CGFloat { tops[i] + heights[i] }

    /// The row whose slot holds `y`: the last whose top is at or above it, clamped to the rows.
    func row(at y: CGFloat) -> Int? {
        guard !isEmpty else { return nil }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The rows whose slots meet `lo...hi`.
    func rows(from lo: CGFloat, to hi: CGFloat) -> Range<Int> {
        guard !isEmpty, hi >= 0, lo <= total, lo <= hi else {
            if !isEmpty, lo > total { return count..<count }
            return 0..<0
        }
        let first = row(at: max(lo, 0)) ?? 0
        let last = row(at: min(hi, total)) ?? 0
        return first..<(last + 1)
    }

    /// Row `i` at a new height; what every row after it moved by.
    @discardableResult
    mutating func setHeight(_ h: CGFloat, at i: Int) -> CGFloat {
        setHeights([(i, h)])
    }

    /// Several rows at new heights at once, every top after the first recomputed once.
    @discardableResult
    mutating func setHeights(_ changes: [(index: Int, height: CGFloat)]) -> CGFloat {
        guard let first = changes.map(\.index).min() else { return 0 }
        let before = total
        for (i, h) in changes { heights[i] = h }
        for i in first..<count { tops[i + 1] = tops[i] + heights[i] + spacing }
        return total - before
    }

    /// The row the reader's place is kept by: the first whose bottom is below the top of what they
    /// see (`y`, in the index's coordinates), with how far down that row they are.
    func anchor(at y: CGFloat) -> (index: Int, offset: CGFloat)? {
        guard var i = row(at: y) else { return nil }
        // In the spacing after a row: the next one holds the place.
        if y >= bottom(i), i + 1 < count { i += 1 }
        return (i, y - tops[i])
    }

    /// The rows to have built for a view of `visible` (in the index's coordinates): those it meets,
    /// and about another view's height either way.
    func window(for visible: ClosedRange<CGFloat>, overscan: CGFloat) -> Range<Int> {
        rows(from: visible.lowerBound - overscan, to: visible.upperBound + overscan)
    }

    /// Whether the rows built, `window`, still cover `visible` with at least `margin` to spare
    /// either way (or reach the end there), so a scroll needn't change them.
    func covers(_ window: Range<Int>, _ visible: ClosedRange<CGFloat>, margin: CGFloat) -> Bool {
        guard !isEmpty else { return true }
        let lo = visible.lowerBound - margin, hi = visible.upperBound + margin
        let topOK = window.lowerBound == 0 || top(window.lowerBound) <= max(lo, 0)
        let bottomOK = window.upperBound >= count || top(window.upperBound) >= min(hi, total)
        return topOK && bottomOK && !window.isEmpty
    }
}

/// Where the running turn begins among the rows: at its prompt (or the date above it). Rows before
/// it are settled history; it and what follows are the live turn, drawn on their own and all built.
/// Rows holding no prompt (a page from the middle of a long turn) are history but for their last
/// few, rather than all built at once.
enum TranscriptSplit {
    static let liveWithoutPrompt = 8

    static func liveStart(_ rows: [TranscriptRow]) -> Int {
        guard let i = rows.lastIndex(where: { row in
            if case .item(.userMessage(let m)) = row { return m.parentToolUseId == nil }
            return false
        }) else { return max(0, rows.count - liveWithoutPrompt) }
        if i > 0, case .dateSeparator(let promptID, _) = rows[i - 1], promptID == rows[i].id { return i - 1 }
        return i
    }
}

/// One row as the transcript draws it: the row, and its turn.
struct TranscriptEntry: Identifiable {
    let row: TranscriptRow
    let place: TurnPlace?
    var id: String { row.id }

    /// Drawn the same: an item's row reads its item live from its box.
    @MainActor func drawsSame(as other: TranscriptEntry, thread: ThreadModel) -> Bool {
        TranscriptRowView(row: row, thread: thread, place: place) == TranscriptRowView(row: other.row, thread: thread, place: other.place)
    }

    /// A short name for its kind, for the height log.
    var kind: String {
        switch row {
        case .item(let item):
            switch item {
            case .agentMessage: "reply"
            case .userMessage(let m):
                m.origin == "wakeup" ? "wakeup" : (m.synthetic == true || m.parentToolUseId != nil || m.origin == "workflow") ? "synthetic" : "prompt"
            case .toolCall: "toolCall"
            case .notice: "notice"
            case .error: "error"
            case .compaction: "compaction"
            default: "item"
            }
        case .toolGroup: "toolGroup"
        case .turnWork: "turnWork"
        case .turnEdits: "turnEdits"
        case .dateSeparator: "date"
        }
    }
}
