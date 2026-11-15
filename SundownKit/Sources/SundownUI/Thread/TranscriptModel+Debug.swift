#if DEBUG
import SwiftUI
import SundownKit

/// What the stress driver (`StressDriver`) asks of the transcript and reads from it.
extension TranscriptModel {
    /// The model the stress driver's `probe` reads: the latest made.
    nonisolated(unsafe) static weak var current: TranscriptModel?

    func listenToStressDriver() {
        NotificationCenter.default.addObserver(forName: .stressScroll, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let edge = info["edge"] as? String, frac = info["frac"] as? CGFloat
            MainActor.assumeIsolated { self?.stressScroll(edge: edge, frac: frac) }
        }
        Self.current = self
    }

    private func stressScroll(edge: String?, frac: CGFloat?) {
        guard !hidden, ready else { return }
        switch edge {
        case "top": scroll(toVisibleTop: view.insetTop - view.contentInsetTop)
        case "bottom": goToEnd()
        default:
            if let frac { scroll(toVisibleTop: frac * max(0, view.content - view.height)) }
        }
    }

    /// The settled row at the top of the view, and where it is on screen.
    private var topRowDescription: String {
        let y = view.visibleTop - historyTop
        guard let (i, offset) = index.anchor(at: y), y < index.total else { return "none" }
        return "\(settled[i].id) \(Int(-offset)) from the top"
    }

    var probe: String {
        let rows = window.prefix(3).map { i in "\(i):\(settled[i].kind)@\(Int(historyTop + index.top(i)))h\(Int(index.height(i)))" }
        let counts = mismatches.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "top=[\(topRowDescription)] settled=\(settled.count) live=\(live.count) window=\(window.lowerBound)..<\(window.upperBound) "
            + "visible=\(Int(view.visibleTop))..\(Int(view.visibleBottom)) offset=\(Int(view.offset)) content=\(Int(view.content)) "
            + "expectedContent≈\(Int(liveTop + live.reduce(0) { $0 + (liveHeights[$1.id] ?? 0) + Self.spacing })) "
            + "following=\(following) far=\(farFromEnd) stale=\(stale.count) width=\(Int(width)) older=\(showsOlder) "
            + "edge=\(edgeArmed ? "bottom" : "nil") mismatches=[\(counts)] [\(rows.joined(separator: " "))]"
    }
}
#endif
