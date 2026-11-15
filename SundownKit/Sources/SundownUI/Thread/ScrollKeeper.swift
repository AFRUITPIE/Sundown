import AppKit
import SwiftUI

/// The one place the transcript reaches into AppKit: it puts the reader back where they were after
/// the rows change under them (an older page going in above, a corrected height, a new width), in
/// the same layout pass as the change, by moving the enclosing scroll view's clip view. SwiftUI's
/// `ScrollPosition` does it in the same frame while the view is still, but not while the reader's
/// wheel is turning: a request made then was never applied (macOS 27.2.1, 2026-11, every binding
/// tried), so an older page that arrived mid-scroll left the reader at its top, and the next page
/// was asked for at once. Find, Previous and Next Prompt and the end use `ScrollPosition`.
struct ScrollKeeper: NSViewRepresentable {
    let model: TranscriptModel

    func makeNSView(context: Context) -> ScrollKeeperView {
        let view = ScrollKeeperView()
        model.keeper = view
        return view
    }

    func updateNSView(_ view: ScrollKeeperView, context: Context) {
        model.keeper = view
    }
}

final class ScrollKeeperView: NSView {
    /// Where the clip view's origin goes (as the scroll geometry's `contentOffset`): at once if the
    /// document already holds it, else as the document is laid out anew (its frame changes as SwiftUI
    /// lays the change out), checked again each turn of the run loop, and after a second as near as
    /// it can. Settling on the first turn was too soon for a change that makes the content much
    /// taller (Every Call in the middle of a chat): SwiftUI hadn't laid it out yet, and the reader
    /// was left at the old content's bottom (2026-11).
    var target: CGFloat? {
        didSet {
            guard target != nil else { return }
            since = .now()
            apply(final: false)
            if target != nil { retry() }
        }
    }

    private var since = DispatchTime.now()
    /// How long to wait for the document to be laid out tall enough: a count of run-loop turns
    /// was too short on CI's slower runner.
    private static let patience: UInt64 = 1_000_000_000

    private func retry() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.target != nil else { return }
            let waited = DispatchTime.now().uptimeNanoseconds - self.since.uptimeNanoseconds
            self.apply(final: waited >= Self.patience)
            if self.target != nil { self.retry() }
        }
    }

    private weak var observed: NSView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let document = enclosingScrollView?.documentView, document !== observed {
            if let observed { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observed) }
            document.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(documentResized), name: NSView.frameDidChangeNotification, object: document)
            observed = document
        }
    }

    @objc private func documentResized() { apply(final: false) }

    private func apply(final: Bool) {
        guard let target, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let lowest = -scroll.contentInsets.top
        let highest = max(lowest, document.frame.height + scroll.contentInsets.bottom - clip.bounds.height)
        // Not until the document is laid out tall enough to hold it.
        guard target <= highest + 0.5 || final else { return }
        self.target = nil
        let y = max(lowest, min(target, highest))
        guard abs(clip.bounds.origin.y - y) >= 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}
